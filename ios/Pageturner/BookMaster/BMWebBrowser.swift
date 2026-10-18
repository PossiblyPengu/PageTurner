import SwiftUI
import WebKit

/// One of the suite's web apps, kept alive so switching away and back finds it where it was left.
///
/// The three share one persistent website data store, so a sign-in survives closing the app. What
/// the page may show, and where everything else goes, is `BMWebPolicy` (pure, Linux-checked).
@Observable @MainActor
final class BMWebPage {
    let app: BMWebApp
    let webView: WKWebView
    private(set) var title = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// The page itself could not be loaded: the whole view says so, with a way to try again.
    var failure: String?
    /// A file the page saved could not be: said once, over a page that is otherwise fine.
    var downloadError: String?
    /// A link in this page that belongs to another app: the browser switches to it.
    @ObservationIgnored var onSwitch: ((BMWebApp, URL) -> Void)?
    /// What was last asked for, so trying again after a failure goes there and not to the front door.
    @ObservationIgnored private(set) var requested: URL?

    private let delegate: BMWebDelegate
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false

    init(app: BMWebApp) {
        let delegate = BMWebDelegate()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // sites can tell it is Pageturner asking
        configuration.applicationNameForUserAgent = "Pageturner"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        let refresh = UIRefreshControl()
        refresh.addTarget(delegate, action: #selector(BMWebDelegate.pulled(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        self.app = app
        self.delegate = delegate
        webView = view
        delegate.page = self
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        observe()
    }

    /// The web view's own state, mirrored for the toolbar. One statement each: a single array of
    /// them takes the type checker too long.
    private func observe() {
        let view = webView
        observers.append(view.observe(\.title) { [weak self] v, _ in
            let value = v.title ?? ""
            Task { @MainActor in self?.title = value }
        })
        observers.append(view.observe(\.url) { [weak self] v, _ in
            let value = v.url
            Task { @MainActor in self?.currentURL = value }
        })
        observers.append(view.observe(\.canGoBack) { [weak self] v, _ in
            let value = v.canGoBack
            Task { @MainActor in self?.canGoBack = value }
        })
        observers.append(view.observe(\.canGoForward) { [weak self] v, _ in
            let value = v.canGoForward
            Task { @MainActor in self?.canGoForward = value }
        })
        observers.append(view.observe(\.estimatedProgress) { [weak self] v, _ in
            let value = v.estimatedProgress
            Task { @MainActor in self?.progress = value }
        })
        observers.append(view.observe(\.isLoading) { [weak self] v, _ in
            let value = v.isLoading
            Task { @MainActor in
                self?.isLoading = value
                if !value { self?.webView.scrollView.refreshControl?.endRefreshing() }
            }
        })
    }

    /// Show `url`, or this app's front door.
    func open(_ url: URL? = nil) {
        failure = nil
        started = true
        let target = url ?? app.start
        requested = target
        webView.load(URLRequest(url: target))
    }

    /// Open it the first time; leave it be after that.
    func openIfNeeded(_ url: URL? = nil) {
        if !started { open(url) }
    }

    /// Again: what is on screen, or — when nothing loaded, or the last load failed — what was asked for.
    func reload() {
        if webView.url == nil || failure != nil {
            open(requested)
        } else {
            failure = nil
            webView.reload()
        }
    }

    /// Back to not having been opened: blank, and loaded afresh the next time it is wanted. For a page
    /// whose content is stale (its sign-in was cleared) or gone (its process was reclaimed while hidden).
    func unload() {
        started = false
        failure = nil
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// The process behind the page was reclaimed. Shown: bring it back. Hidden: let it be loaded when next wanted.
    func recover() {
        guard webView.window != nil else {
            started = false
            return
        }
        if webView.url != nil { webView.reload() } else { open(requested) }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
}

/// The three pages, made as they are first wanted.
@Observable @MainActor
final class BMWebPages {
    static let shared = BMWebPages()

    @ObservationIgnored private var pages: [BMWebApp: BMWebPage] = [:]
    /// The one on screen.
    @ObservationIgnored var visible: BMWebApp?
    /// What to do with a link into another of the apps: set by the browser on screen, applied to every page.
    @ObservationIgnored var onSwitch: ((BMWebApp, URL) -> Void)?
    @ObservationIgnored private var warning: NSObjectProtocol?

    private init() {
        // files the pages saved on an earlier run, and were never cleaned up after
        try? FileManager.default.removeItem(at: BMWebPresenter.downloads)
        warning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shed() }
        }
    }

    func page(for app: BMWebApp) -> BMWebPage {
        if let page = pages[app] { return page }
        let page = BMWebPage(app: app)
        page.onSwitch = { [weak self] target, url in self?.onSwitch?(target, url) }
        pages[app] = page
        return page
    }

    /// Low on memory: let go of the pages nobody is looking at; they are made and loaded again when wanted.
    private func shed() {
        for (app, page) in pages where app != visible && page.webView.window == nil { pages[app] = nil }
    }

    /// Forget every sign-in and everything the sites stored. The pages stay — a browser on screen is
    /// still showing one — but start over: the one in view at its front door, the others when next opened.
    func clearSignIns() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for page in pages.values { page.unload() }
        if let visible, let page = pages[visible], page.webView.window != nil { page.open() }
        BMQuestLogRoomPage.shared.forget()
    }
}

/// What the web view asks of the app: what it may show, what to hand to iOS, the page's own
/// dialogs, and a download it cannot display.
@MainActor
final class BMWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var page: BMWebPage?
    private var destinations: [ObjectIdentifier: URL] = [:]

    @objc func pulled(_ sender: UIRefreshControl) {
        page?.reload()
    }

    // MARK: Where it may go

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch BMWebPolicy.decide(url, mainFrame: mainFrame) {
        case .block:
            return .cancel
        case .external:
            openExternally(url)
            return .cancel
        case .allow:
            if action.shouldPerformDownload { return .download }
            // a link into another of the apps opens that app's own page, so the switch always says where you are
            if mainFrame, let page, url.scheme == "https", BMWebApp.app(for: url) != page.app {
                switchAway(from: page, to: url)
                return .cancel
            }
            return .allow
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame else { return .allow }
        let attachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        return response.canShowMIMEType && !attachment ? .allow : .download
    }

    // a link that asks for a new window (target=_blank, window.open): here if it is ours and secure, Safari if not;
    // nothing for about:blank or blob:, which a page uses to build a document of its own
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        switch BMWebPolicy.newWindow(url) {
        case .allow:
            if let page, BMWebApp.app(for: url) != page.app {
                switchAway(from: page, to: url)
            } else {
                webView.load(action.request)
            }
        case .external:
            openExternally(url)
        case .block:
            break
        }
        return nil
    }

    /// Hand `url` to the browser to show in its own app's page. A BookMaster page that only handed the
    /// reader on ("Linking Kindred…") has nothing left to show, so it goes back to its front door
    /// rather than stay on that card.
    private func switchAway(from page: BMWebPage, to url: URL) {
        let handoff = BMWebApp.isHandoff(page.webView.url)
        page.onSwitch?(BMWebApp.app(for: url), url)
        if handoff { page.open() }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    // MARK: How it went

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        page?.failure = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.recover()
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // our own refusals, and a navigation turned into a download, are not failures
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 || ns.code == 101 { return }
        page?.failure = ns.localizedDescription
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = BMWebPresenter.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let file = folder.appendingPathComponent(BMWebPolicy.safeFileName(suggestedFilename))
        destinations[ObjectIdentifier(download)] = file
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // what the site made, handed to the reader: Save to Files, AirDrop, Share — and gone from here afterwards
        BMWebPresenter.share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        // said over the page, which is fine: a failed save is not a failed page
        page?.downloadError = error.localizedDescription
    }

    // MARK: The page's own dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await BMWebPresenter.ask(host: frame.request.url?.host, message: message, input: nil, cancellable: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await BMWebPresenter.ask(host: frame.request.url?.host, message: message, input: nil, cancellable: true) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await BMWebPresenter.ask(host: frame.request.url?.host, message: prompt, input: defaultText ?? "", cancellable: true)
    }
}

/// Putting things in front of the reader from outside the SwiftUI tree.
@MainActor
enum BMWebPresenter {
    /// Where saved files wait for the share sheet.
    static var downloads: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("web-downloads", isDirectory: true)
    }

    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    /// The share sheet for a file the page saved; the file (and its folder) is removed when the sheet is done with it.
    static func share(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard let controller = top() else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: folder)
        }
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
        controller.present(sheet, animated: true)
    }

    /// A page's alert, confirm or prompt. `nil`: cancelled; otherwise OK (with the text, for a prompt).
    static func ask(host: String?, message: String, input: String?, cancellable: Bool) async -> String? {
        guard let controller = top() else { return cancellable ? nil : "" }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: host, message: message, preferredStyle: .alert)
            if input != nil { alert.addTextField { $0.text = input } }
            if cancellable {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text ?? "")
            })
            controller.present(alert, animated: true)
        }
    }
}

/// Where the browser opens, and on what.
struct BMWebLaunch: Identifiable, Hashable {
    var app: BMWebApp
    /// A particular page — a notice's — or nil for the app's front door.
    var url: URL?
    let id = UUID()
}

/// The suite's web apps, inside Pageturner: BookMaster, Kindred and Quest Log behind a switch.
struct BMWebBrowserView: View {
    let launch: BMWebLaunch
    @State private var app: BMWebApp
    /// The page asked for is opened once; coming back to the tab later leaves the reader where they were.
    @State private var opened = false

    init(launch: BMWebLaunch) {
        self.launch = launch
        _app = State(initialValue: launch.app)
    }

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        let page = BMWebPages.shared.page(for: app)
        return lifecycle(chrome(page, content: stack(page))).hidesChatButton()
    }

    private func stack(_ page: BMWebPage) -> some View {
        ZStack(alignment: .top) {
            BMWebHost(page: page)
            if page.isLoading, page.progress < 1 {
                ProgressView(value: page.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.ptAccent)
            }
            if let failure = page.failure {
                failureView(failure, page: page)
            }
        }
    }

    /// The title bar, the switch and menu in it, and the alert for a file that would not save.
    private func chrome<V: View>(_ page: BMWebPage, content: V) -> some View {
        content
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { barItems(page) }
            .alert("Couldn’t save the file", isPresented: downloadAlert(page)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(page.downloadError ?? "")
            }
    }

    private func lifecycle<V: View>(_ content: V) -> some View {
        content
            .onAppear { arrive() }
            .onDisappear { BMWebPages.shared.visible = nil }
            .onChange(of: app) { _, next in
                BMWebPages.shared.visible = next
                BMWebPages.shared.page(for: next).openIfNeeded()
            }
    }

    private func downloadAlert(_ page: BMWebPage) -> Binding<Bool> {
        Binding(
            get: { page.downloadError != nil },
            set: { if !$0 { page.downloadError = nil } })
    }

    /// Be the browser on screen: take the links into other apps, and open what was asked for — once.
    private func arrive() {
        let pages = BMWebPages.shared
        pages.visible = app
        pages.onSwitch = { target, url in
            app = target
            pages.page(for: target).open(url)
        }
        guard !opened else {
            pages.page(for: app).openIfNeeded()
            return
        }
        opened = true
        if let url = launch.url {
            pages.page(for: launch.app).open(url)
        } else {
            pages.page(for: app).openIfNeeded()
        }
    }

    @ToolbarContentBuilder
    private func barItems(_ page: BMWebPage) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("App", selection: $app) {
                ForEach(BMWebApp.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 270)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { page.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!page.canGoBack)
                Button { page.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!page.canGoForward)
                Button { page.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                if let url = BMWebPolicy.shareable(page.currentURL) {
                    Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Page options")
        }
    }

    private func failureView(_ message: String, page: BMWebPage) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open \(page.app.name)", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { page.reload() }
                .ptButtonStyle(prominent: true)
        }
        .background(Color(.systemBackground))
    }
}

/// A page's web view, as a SwiftUI view. The web view goes inside a box this view owns, and follows the
/// page: if the page is replaced (reclaimed for memory, or started over) the new one takes its place, so
/// what is on screen is always the page the toolbar and the failure view are talking about.
struct BMWebHost: UIViewRepresentable {
    let page: BMWebPage

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        attach(page.webView, to: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        guard page.webView.superview !== box else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        attach(page.webView, to: box)
    }

    private func attach(_ web: WKWebView, to box: UIView) {
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: box.topAnchor),
            web.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
    }
}
