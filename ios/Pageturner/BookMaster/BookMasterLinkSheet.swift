import SwiftUI
import WebKit

/// BookMaster's pair flow, in a web view the app owns.
///
/// The reader signs in on BookMaster's own page; BookMaster then sends the
/// browser back to `https://pageturner.pages.dev/?bm-link=<code>`. This view
/// takes that redirect apart before it is requested and hands the one-time code
/// to the app, so linking works whether or not the Pageturner website has been
/// deployed (an `ASWebAuthenticationSession` can only be ended by a custom-scheme
/// redirect, which needed a deployed page to make it).
struct BookMasterLinkSheet: View {
    /// Called once with the code; the sheet is then done.
    let onCode: (String) -> Void
    let onCancel: () -> Void

    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                LinkWebView(attempt: attempt, onCode: onCode, loading: $loading, failure: $failure)
                    .ignoresSafeArea(edges: .bottom)
                if loading && failure == nil {
                    ProgressView().controlSize(.large)
                }
                if let failure {
                    ContentUnavailableView {
                        Label("Couldn’t reach BookMaster", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") {
                            self.failure = nil
                            loading = true
                            attempt += 1
                        }
                        .ptButtonStyle(prominent: true)
                    }
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle("Link BookMaster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        // a pageturner://link URL is only believed while a flow the reader started is open
        .onAppear { BookMasterLinker.shared.pending = true }
        .onDisappear { BookMasterLinker.shared.pending = false }
    }
}

private struct LinkWebView: UIViewRepresentable {
    /// Bumped to start the flow over.
    let attempt: Int
    let onCode: (String) -> Void
    @Binding var loading: Bool
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // the shared store, the one BookMaster's pages in the tabs use: signing in here signs them in too, once. (Unlinking,
        // or signing out of the web apps in Settings, forgets it — `BMWebPages.clearSignIns`.)
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.started = attempt
        view.load(URLRequest(url: Self.startURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.started != attempt {
            context.coordinator.started = attempt
            context.coordinator.finished = false
            view.load(URLRequest(url: Self.startURL))
        }
    }

    private static var startURL: URL {
        #if DEBUG
        // CI simulator run: start from another address to exercise the redirect (Debug/DebugScenario.swift)
        if let raw = UserDefaults.standard.string(forKey: "PTDebugLinkStart"), let url = URL(string: raw) { return url }
        #endif
        return BMLinkURL.start
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LinkWebView
        var started = 0
        /// The code is handed over once, however many times the redirect fires.
        var finished = false

        init(_ parent: LinkWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }

            // the end of the flow: BookMaster sending the code home
            if let code = BMLinkURL.code(from: url) {
                if !finished {
                    finished = true
                    parent.onCode(code)
                }
                return .cancel
            }
            // only BookMaster's own pages open in the sheet (data:/about: plumbing is left alone)
            if action.targetFrame?.isMainFrame ?? true,
               url.scheme == "https" || url.scheme == "http",
               !BMLinkURL.isBookMasterPage(url)
            {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.failure = "The page stopped responding."
        }

        private func report(_ error: Error) {
            let ns = error as NSError
            // a navigation we cancelled ourselves (the redirect home) is not a failure
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
            parent.loading = false
            parent.failure = ns.localizedDescription
        }
    }
}
