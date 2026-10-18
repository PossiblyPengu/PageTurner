import Foundation

/// Instant notifications through Bark, as BookMaster describes them. A sideloaded app has no push
/// entitlement, so the free Bark iOS app — which has a push service of its own — does the delivering:
/// the reader pastes the key Bark shows them, and BookMaster sends every suite notice (chat,
/// suggestions, Kindred, Quest Log) there. Unlike ntfy.sh it has no per-address limit for BookMaster's
/// shared server address to run into. Pure — no UIKit — so the rules can be checked off-device.
struct BMBarkStatus: Decodable, Equatable {
    /// False when this BookMaster has no usable Bark server.
    var available: Bool
    var server: String?
    var configured: Bool
    /// The last four characters of the key, to say which device is set. The key itself is never sent back.
    var keyHint: String?
    /// Where a tap goes: "web" or "pageturner".
    var link: String?
    /// Whether a chat message's words are sent (off: only who wrote).
    var preview: Bool

    var isOn: Bool { configured }
    var opensPageturner: Bool { link == "pageturner" }
}

enum BMBark {
    /// The app on the App Store.
    static let appStore = URL(string: "https://apps.apple.com/us/app/bark-customed-notifications/id1403753865")!
    /// Its own address, to open it when it is installed.
    static let appScheme = URL(string: "bark://")!

    /// What a device key looks like: letters and digits, long enough not to be a word.
    private static func isKey(_ text: String) -> Bool {
        (8 ... 64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The key out of whatever was pasted: the key itself, or the address Bark shows beside it
    /// (`https://api.day.app/<key>/…`). Nil for anything else — the same rule BookMaster applies.
    static func key(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKey(text) { return text }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let first = url.path.split(separator: "/").first.map(String.init)
        if let first, isKey(first) { return first }
        return nil
    }

    /// The server as a name: "api.day.app", not "https://api.day.app".
    static func serverLabel(_ server: String?) -> String {
        guard let server, let host = URL(string: server)?.host else { return "api.day.app" }
        return host
    }

    /// Whether Pageturner is on the way to being stood down: either instant channel is on.
    static func instantActive(ntfy: Bool, bark: Bool) -> Bool { ntfy || bark }
}
