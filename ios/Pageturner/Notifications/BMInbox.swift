import Foundation

/// Pageturner's own notifications: what the reader has been told, kept as a list they can come back to —
/// a suggestion from the other reader, a chat message, something new in Kindred or Quest Log. The feed
/// only says what is waiting *now* (a message you have read drops out of it), so this keeps the history.
/// Pure — no UIKit — so the rules can be checked off-device; `BMInboxStore` keeps the list and
/// `BMInboxView` shows it.
struct BMInboxItem: Codable, Identifiable, Equatable {
    /// "nudge:<id>" or "notice:<id>" — the keys `NotificationPlan` already uses.
    var id: String
    /// "bookmaster", "kindred", "quest-log" or "pageturner": whose it is (and so how its dot looks).
    var app: String
    var title: String
    var body: String
    /// A notice's page inside its own app; nil for a suggestion, which lives on the Together tab.
    var path: String?
    /// When it was first seen, in seconds since 1970.
    var at: Double
    var read: Bool
}

enum BMInbox {
    /// The newest this many are kept.
    static let keep = 100

    /// What is waiting, as items, worded the way a notification for it would be.
    static func items(nudges: [BMNudge], notices: [BMNotice], now: Double) -> [BMInboxItem] {
        let suggestions = nudges.map { nudge -> BMInboxItem in
            let item = NotificationPlan.nudgeItem(nudge)
            return BMInboxItem(id: item.id, app: "bookmaster", title: item.title, body: item.body, path: nil, at: now, read: false)
        }
        let others = notices.map { notice in
            BMInboxItem(
                id: "notice:\(notice.id)", app: notice.app, title: NotificationPlan.appName(notice.app),
                body: notice.text, path: notice.path, at: now, read: false)
        }
        return suggestions + others
    }

    /// Fold what is waiting into the history. What is already held keeps its place, its time and whether
    /// it has been read (its words are brought up to date — a chat notice's text changes with the newest
    /// message); anything new is added, unread. Newest first, and no more than `keep`.
    static func merge(_ held: [BMInboxItem], with waiting: [BMInboxItem]) -> [BMInboxItem] {
        var byId = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in waiting {
            if var existing = byId[item.id] {
                existing.title = item.title
                existing.body = item.body
                existing.path = item.path
                byId[item.id] = existing
            } else {
                byId[item.id] = item
            }
        }
        let ordered = byId.values.sorted { a, b in a.at != b.at ? a.at > b.at : a.id < b.id }
        return Array(ordered.prefix(keep))
    }

    static func unreadCount(_ items: [BMInboxItem]) -> Int { items.filter { !$0.read }.count }

    /// The same list with these read (all of them, when no ids are given).
    static func markingRead(_ items: [BMInboxItem], ids: Set<String>? = nil) -> [BMInboxItem] {
        items.map { item in
            guard ids?.contains(item.id) ?? true else { return item }
            var read = item
            read.read = true
            return read
        }
    }

    static func removing(_ items: [BMInboxItem], id: String) -> [BMInboxItem] {
        items.filter { $0.id != id }
    }

    /// Where an item leads.
    enum Destination: Equatable {
        /// The Together tab: suggestions are answered there.
        case together
        /// The shared chat.
        case chat
        /// A page of one of the web apps, opened in here.
        case web(BMWebApp, URL)
    }

    static func destination(for item: BMInboxItem) -> Destination {
        if item.id.hasPrefix("notice:" + BMChat.noticePrefix) { return .chat }
        guard item.id.hasPrefix("notice:"),
              let found = BMWebApp.destination(noticeApp: item.app, path: item.path)
        else { return .together }
        return .web(found.app, found.url)
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago".
    static func ago(_ at: Double, now: Double) -> String {
        let seconds = max(0, now - at)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }
}

/// Keeping Pageturner running in the background so it can tell the reader at once: a silent sound the
/// system counts as playing audio, and a look at BookMaster every half minute. Pure rules here;
/// `BackgroundKeepAlive` does the playing.
enum BMKeepAlive {
    /// Hold the app awake only when the reader asked for it, BookMaster is linked, and the app is not in front
    /// (in front it is awake anyway, and looks on its own).
    static func shouldRun(enabled: Bool, linked: Bool, background: Bool) -> Bool {
        enabled && linked && background
    }

    /// How often it looks: every half minute, and every minute and a half in Low Power Mode.
    static func pollInterval(lowPower: Bool) -> TimeInterval { lowPower ? 90 : 30 }

    /// How often the app itself looks while it is in front — a banner arriving two minutes late
    /// beats a request every half minute; the background keep-alive stays snappier.
    static func foregroundPollInterval(lowPower: Bool) -> TimeInterval { lowPower ? 180 : 120 }

    /// A WAV file of silence: 16-bit mono PCM, `seconds` long. Played on a loop it is a sound the system
    /// counts, and nobody hears.
    static func silence(seconds: Int = 1, sampleRate: Int = 8000) -> Data {
        let bytes = max(1, seconds) * sampleRate * 2
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); le32(36 + bytes); text("WAVE")
        text("fmt "); le32(16); le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        text("data"); le32(bytes)
        data.append(Data(count: bytes))
        return data
    }
}
