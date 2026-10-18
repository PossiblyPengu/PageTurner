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
    var failure: String?
    /// A link in this page that belongs to another app: the browser switches to it.
    @ObservationIgnored var onSwitch: ((BMWebApp, URL) -> Void)?

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

    /// Show `url`, or this app's front door the first time it is opened.
    func open(_ url: URL? = nil) {
        failure = nil
        started = true
        webView.load(URLRequest(url: url ?? app.start))
    }

    /// Open it the first time; leave it be after that.
    func openIfNeeded() {
        if !started { open() }
    }

    func reload() {
        failure = nil
        if webView.url == nil { open() } else { webView.reload() }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
}

/// The three pages, made as they are first wanted.
@Observable @MainActor
final class BMWebPages {
    static let shared = BMWebPages()

    @ObservationIgnored private var pages: [BMWebApp: BMWebPage] = [:]
    /// The one on screen, which a memory warning leaves alone.
    @ObservationIgnored var visible: BMWebApp?
    @ObservationIgnored private var warning: NSObjectProtocol?

    private init() {
        warning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shed() }
        }
    }

    func page(for app: BMWebApp) -> BMWebPage {
        if let page = pages[app] { return page }
        let page = BMWebPage(app: app)
        pages[app] = page
        return page
    }

    /// Low on memory: let go of the pages nobody is looking at; they reload when next opened.
    private func shed() {
        for app in pages.keys where app != visible { pages[app] = nil }
    }

    /// Forget every sign-in and everything the sites stored, and start the pages over.
    func clearSignIns() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        pages.removeAll()
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
                page.onSwitch?(BMWebApp.app(for: url), url)
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

    // a link that asks for a new window (target=_blank): here if it is ours, Safari if not
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        switch BMWebPolicy.decide(url, mainFrame: true) {
        case .allow:
            if let page, BMWebApp.app(for: url) != page.app { page.onSwitch?(BMWebApp.app(for: url), url) } else { webView.load(action.request) }
        case .external:
            openExternally(url)
        case .block:
            break
        }
        return nil
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
        // the page's process was reclaimed (memory): bring it back rather than leave it blank
        webView.reload()
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
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let file = folder.appendingPathComponent(BMWebPolicy.safeFileName(suggestedFilename))
        destinations[ObjectIdentifier(download)] = file
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // what the site made, handed to the reader: Save to Files, AirDrop, Share
        BMWebPresenter.share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        page?.failure = error.localizedDescription
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
    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    static func share(_ file: URL) {
        guard let controller = top() else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
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

    init(launch: BMWebLaunch) {
        self.launch = launch
        _app = State(initialValue: launch.app)
    }

    var body: some View {
        let page = BMWebPages.shared.page(for: app)
        ZStack(alignment: .top) {
            BMWebHost(page: page)
                .id(app)
                .ignoresSafeArea(edges: .bottom)
            if page.isLoading, page.progress < 1 {
                ProgressView(value: page.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.ptAccent)
            }
            if let failure = page.failure {
                failureView(failure, page: page)
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { barItems(page) }
        .onAppear { arrive() }
        .onDisappear { BMWebPages.shared.visible = nil }
        .onChange(of: app) { _, next in
            BMWebPages.shared.visible = next
            BMWebPages.shared.page(for: next).openIfNeeded()
        }
    }

    /// Open the page the reader asked for, and be ready to follow a link into another app.
    private func arrive() {
        let pages = BMWebPages.shared
        pages.visible = app
        for each in BMWebApp.allCases {
            pages.page(for: each).onSwitch = { target, url in
                app = target
                pages.page(for: target).open(url)
            }
        }
        if let url = launch.url {
            pages.page(for: app).open(url)
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

/// A page's web view, as a SwiftUI view.
private struct BMWebHost: UIViewRepresentable {
    let page: BMWebPage

    func makeUIView(context: Context) -> WKWebView { page.webView }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
