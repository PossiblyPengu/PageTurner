import Foundation

/// Instant notifications through ntfy, as BookMaster describes them. A sideloaded app has no push
/// entitlement, so the free ntfy iOS app does the delivering: BookMaster publishes every suite
/// notice (chat, suggestions, Kindred, Quest Log) to a private topic, and ntfy shows it at once.
/// Pure — no UIKit — so the wording and rules can be checked off-device.
struct BMNtfyStatus: Decodable, Equatable {
    /// False when this BookMaster has no usable ntfy server.
    var available: Bool
    var server: String?
    /// The reader's private topic; nil until it is switched on.
    var topic: String?
    /// Where a tap goes: "web" or "pageturner".
    var link: String?
    /// Whether a chat message's words are sent (off: only who wrote).
    var preview: Bool

    var isOn: Bool { topic != nil }
    var opensPageturner: Bool { link == "pageturner" }
}

enum BMNtfy {
    /// The app on the App Store.
    static let appStore = URL(string: "https://apps.apple.com/us/app/ntfy/id1625396347")!
    /// Its own address, to open it when it is installed.
    static let appScheme = URL(string: "ntfy://")!

    /// The server as someone would type it into ntfy: "ntfy.sh", not "https://ntfy.sh".
    static func serverLabel(_ server: String?) -> String {
        guard let server, let host = URL(string: server)?.host else { return "ntfy.sh" }
        return host
    }

    /// Whether the app should ask BookMaster again whether ntfy is on, given when it last did. Often
    /// enough to notice a change made on the web, rarely enough to cost nothing.
    static func shouldRecheck(lastChecked: Double, now: Date = Date(), every: TimeInterval = 6 * 3600) -> Bool {
        now.timeIntervalSince1970 - lastChecked >= every || lastChecked > now.timeIntervalSince1970
    }
}
