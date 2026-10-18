import Foundation

/// The suite's three web apps, opened inside Pageturner, and the rules for where that browser
/// may go. Pure — no WebKit — so the rules can be checked off-device.
///
/// All three are served from BookMaster's address (BookMaster at the root, Kindred under
/// `/kindred/`, Quest Log under `/quest-log/`), so one browser and one sign-in cover the set, and a
/// link from one to another stays inside it. Anything else is not ours to show: it opens in Safari.
enum BMWebApp: String, CaseIterable, Identifiable {
    case bookmaster
    case kindred
    case questLog = "quest-log"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bookmaster: return "BookMaster"
        case .kindred: return "Kindred"
        case .questLog: return "Quest Log"
        }
    }

    /// An SF Symbol for it.
    var symbol: String {
        switch self {
        case .bookmaster: return "books.vertical"
        case .kindred: return "heart"
        case .questLog: return "target"
        }
    }

    /// What a notice's path is relative to. Kindred's notices say `/today`, which is `/kindred/today` on the shared
    /// host; Quest Log's already say `/quest-log` (BookMaster's `useAppOrigins` joins them the same way:
    /// Kindred's origin includes its folder, Quest Log's is the bare host).
    var noticePrefix: String {
        switch self {
        case .kindred: return "/kindred"
        case .bookmaster, .questLog: return ""
        }
    }

    /// Where its own pages live on the shared host.
    var prefix: String {
        switch self {
        case .bookmaster: return ""
        case .kindred: return "/kindred"
        case .questLog: return "/quest-log"
        }
    }

    /// Where opening it begins — each app's front door.
    var start: URL {
        switch self {
        case .bookmaster: return Self.url("/dashboard")
        case .kindred: return Self.url("/kindred/today")
        case .questLog: return Self.url("/quest-log/")
        }
    }

    private static func url(_ path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = BMLinkURL.bookMasterHost
        parts.path = path
        return parts.url!
    }

    /// Which app a page belongs to, by where it sits on the shared host.
    static func app(for url: URL) -> BMWebApp {
        let path = url.path.lowercased()
        for app in [BMWebApp.kindred, .questLog] {
            if path == app.prefix || path.hasPrefix(app.prefix + "/") { return app }
        }
        return .bookmaster
    }

    /// An app's own path — as the suite's notices give it — on the shared host. Nil for anything
    /// that is not a plain path inside the app (`//elsewhere`, a full address, odd characters).
    static func url(app: BMWebApp, path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = BMLinkURL.bookMasterHost
        var rest = path
        if let q = rest.firstIndex(of: "?") {
            parts.percentEncodedQuery = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        parts.percentEncodedPath = app.noticePrefix + rest
        guard let url = parts.url, url.host?.lowercased() == BMLinkURL.bookMasterHost else { return nil }
        return url
    }

    /// Where a notice from the feed opens: its app, its path. Nil for Pageturner's own (it is
    /// already here) and for a notice naming an app we do not know.
    static func destination(noticeApp: String, path: String?) -> (app: BMWebApp, url: URL)? {
        guard let path, let app = BMWebApp(rawValue: noticeApp), let url = url(app: app, path: path) else { return nil }
        // the page decides which app it belongs to, whatever the notice claimed
        return (BMWebApp.app(for: url), url)
    }

    /// A BookMaster page that only hands the reader on to another app — "Linking Kindred…" — and has
    /// nothing to come back to once it has.
    static func isHandoff(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == BMLinkURL.bookMasterHost else { return false }
        return url.path.hasPrefix("/link/")
    }
}

/// What the browser does with an address it is asked to go to.
enum BMWebPolicy {
    enum Decision: Equatable {
        /// Show it here.
        case allow
        /// Hand it to iOS: Safari, Mail, the phone.
        case external
        /// Do nothing.
        case block
    }

    /// `mainFrame` is false for a frame inside a page, which is let through: it is the page's own
    /// content, not somewhere the reader was taken.
    static func decide(_ url: URL, mainFrame: Bool) -> Decision {
        switch url.scheme?.lowercased() {
        case "https":
            if url.host?.lowercased() == BMLinkURL.bookMasterHost { return .allow }
            return mainFrame ? .external : .allow
        case "http":
            // never shown here, even for our own host — iOS would refuse the load anyway
            return mainFrame ? .external : .block
        case "about":
            return .allow
        case "blob":
            return .allow
        case "data":
            // a page can build one, and a reader cannot tell what it is: fine inside a page, not as the page
            return mainFrame ? .block : .allow
        case "mailto", "tel", "sms", "facetime":
            return .external
        default:
            // includes javascript:, file: and pageturner:// — a page may not steer the app
            return .block
        }
    }

    /// A name safe to save a download under: the file's own name, no folders, no oddities.
    static func safeFileName(_ suggested: String) -> String {
        let last = suggested.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && $0 != ":" })
            .trimmingCharacters(in: .whitespaces)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.isEmpty { return "download" }
        guard trimmed.count > 100 else { return trimmed }
        // too long: shorten the name, never the extension
        let ext = NSString(string: trimmed).pathExtension
        guard !ext.isEmpty, ext.count <= 10 else { return String(trimmed.prefix(100)) }
        let stem = String(NSString(string: trimmed).deletingPathExtension.prefix(100 - ext.count - 1))
        return "\(stem).\(ext)"
    }

    /// What a page that asks for a new window (`window.open`, `target=_blank`) gets. Only a secure address
    /// is ever acted on: `about:blank` and `blob:` windows are how a page builds its own document, and
    /// loading them over the page the reader is on would blank it. Refused, the page sees `window.open`
    /// fail and falls back to a plain link.
    static func newWindow(_ url: URL) -> Decision {
        guard url.scheme?.lowercased() == "https" else { return .block }
        return decide(url, mainFrame: true)
    }

    /// An address worth offering to open in Safari: the page itself, never plumbing.
    static func shareable(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}
