import Foundation

/// What a reader's level is called — the bands the web's `levelTitle` spells,
/// kept in the same order so the two apps never disagree about a name.
func bmLevelTitle(_ level: Int) -> String {
    switch level {
    case ..<5: return "Novice Reader"
    case ..<10: return "Casual Reader"
    case ..<20: return "Devoted Reader"
    case ..<35: return "Book Enthusiast"
    case ..<50: return "Bibliophile"
    case ..<75: return "Scholar"
    case ..<100: return "Sage"
    default: return "Legendary Reader"
    }
}

/// Whose dot it is, before it is read. Everything waiting in Quest Log is blue and square — its own
/// accent, and a shape a colour-blind reader can tell too; everything else is round and in the app's
/// accent. BookMaster, Kindred and Quest Log keep the same rule (`suiteTone` there).
enum BMDotTone: Equatable {
    case regular, questLog
}

/// The suite's shared vocabulary — each app's name and what its screens are
/// called. Mirrors presence.ts's SUITE so a beat reads the same on every app.
enum BMSuite {
    static let names: [String: String] = [
        "bookmaster": "BookMaster",
        "quest-log": "Quest Log",
        "kindred": "Kindred",
        "pageturner": "Pageturner",
    ]

    /// The look of a dot about this app (a notice's `app`).
    static func dotTone(forApp app: String) -> BMDotTone { app == "quest-log" ? .questLog : .regular }

    /// A count of notices wears Quest Log's look only when nothing else is waiting.
    static func dotTone(forNotices notices: [BMNotice]) -> BMDotTone {
        !notices.isEmpty && notices.allSatisfy { dotTone(forApp: $0.app) == .questLog } ? .questLog : .regular
    }

    /// Each app's screens in the words the suite shares. Unknown screens still
    /// count as "in there" — the fallback is deliberately vague, like the web's.
    static let places: [String: [String: String]] = [
        "bookmaster": [
            "today": "today", "library": "the library", "book": "a book",
            "series": "a series", "search": "finding a book",
            "progress": "their progress", "together": "Together",
            "chat": "the chat", "profile": "their profile",
        ],
        "quest-log": [
            "dashboard": "the dashboard", "operations": "missions",
            "play": "rewards", "settings": "settings", "chat": "the chat",
            "map": "the map",
        ],
        "kindred": [
            "today": "today’s question", "ask": "questions",
            "activities": "activities", "notes": "notes", "us": "your story",
            "profile": "settings",
        ],
        "pageturner": [
            "library": "the library", "reader": "a book", "player": "the player",
            "bookmaster": "the BookMaster tab", "chat": "the chat",
            "stats": "their stats", "settings": "settings",
        ],
    ]

    /// The one place to say they are: an app they are in right now (the most
    /// recently heard from, if two), else the one they were last seen in —
    /// the web's `whereabouts`, beat for beat. The walk is ordered so two apps
    /// heard from at the same moment pick the same winner every time.
    static func whereabouts(_ apps: [String: BMAppBeat]) -> (app: String, online: Bool, place: String?, lastSeenAt: Double)? {
        var best: (app: String, online: Bool, place: String?, lastSeenAt: Double)?
        for (app, beat) in apps.sorted(by: { $0.key < $1.key }) {
            guard names[app] != nil else { continue }
            let place = beat.place.flatMap { places[app]?[$0] }
            let candidate = (app: app, online: beat.online, place: place, lastSeenAt: beat.lastSeenAt)
            if let current = best {
                let wins = (candidate.online && !current.online)
                    || (candidate.online == current.online && candidate.lastSeenAt > current.lastSeenAt)
                guard wins else { continue }
            }
            best = candidate
        }
        return best
    }

    /// "In Pageturner · a book", or "Last seen 5m ago in Kindred" — the line
    /// every member card carries. Nil when the suite has never heard from them.
    static func whereaboutsLine(_ apps: [String: BMAppBeat]?, now: Date = Date()) -> String? {
        guard let w = whereabouts(apps ?? [:]) else { return nil }
        let name = names[w.app] ?? w.app
        return w.online
            ? "In \(name) · \(w.place ?? "looking around")"
            : "Last seen \(lastSeen(w.lastSeenAt, now: now)) in \(name)"
    }

    /// "just now", "5m ago", "2h ago", "3d ago" — for heartbeats in ms.
    static func lastSeen(_ ms: Double, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince1970 * 1000 - ms
        if diff < 60_000 { return "just now" }
        if diff < 3_600_000 { return "\(Int(diff / 60_000))m ago" }
        if diff < 86_400_000 { return "\(Int(diff / 3_600_000))h ago" }
        return "\(Int(diff / 86_400_000))d ago"
    }

    /// SQLite's "YYYY-MM-DD HH:MM:SS" is UTC — parseDbDate's spelling.
    private static let sqlDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let sqlDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseSql(_ s: String) -> Date? {
        sqlDay.date(from: s) ?? sqlDateOnly.date(from: s)
    }

    /// "today", "yesterday", "4d ago" — the web's timeAgo for a shelf row's
    /// dates, which arrive as SQL strings.
    static func timeAgo(_ sql: String?, now: Date = Date()) -> String? {
        guard let sql, let date = parseSql(sql) else { return nil }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 0 { return "just now" }
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }
}
