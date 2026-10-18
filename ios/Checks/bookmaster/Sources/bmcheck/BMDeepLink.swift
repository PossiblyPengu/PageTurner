import Foundation

/// `pageturner://open?app=<app>&path=<path>` — what a notification's tap carries when BookMaster is
/// told to open Pageturner. `app` and `path` are a suite notice's own (BookMaster's `SuiteNotice`):
/// which app it is from, and a path inside it.
///
/// Anyone can make such an address, so it can only ever reach one of the three web apps on
/// BookMaster's own host, or the native chat — nothing else (`BMWebApp.url` decides that).
/// Pure, so the rules can be checked off-device.
enum BMDeepLink {
    enum Target: Equatable {
        /// The shared chat, which has a native screen.
        case chat
        case web(BMWebApp, URL)
    }

    static let host = "open"

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == BMLinkURL.scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let app = items.first(where: { $0.name == "app" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value
        else { return nil }
        if app == "bookmaster", bare(path) == "/chat" { return .chat }
        guard let found = BMWebApp.destination(noticeApp: app, path: path) else { return nil }
        return .web(found.app, found.url)
    }

    /// A path without its query or fragment.
    private static func bare(_ path: String) -> String {
        String(path.prefix { $0 != "?" && $0 != "#" })
    }
}
