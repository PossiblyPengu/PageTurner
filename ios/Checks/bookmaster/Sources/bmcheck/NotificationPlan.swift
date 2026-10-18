import Foundation

/// What to tell the reader about, given what BookMaster says is waiting and what
/// they have already been told. Pure logic — the Notifier does the asking and the
/// posting — so the rules can be checked off-device.
enum NotificationPlan {
    struct Item: Equatable {
        var id: String
        var title: String
        var body: String
    }

    /// A pile at once reads as one line instead of a burst of banners.
    static let batchAbove = 3

    /// The new things since `seen` — and the set to remember afterwards, which is
    /// just what is waiting now (an answered suggestion drops out, so the set
    /// never grows). `seen` is nil the first time round, when everything already
    /// waiting counts as seen rather than being announced all at once.
    static func plan(nudges: [BMNudge], notices: [BMNotice], seen: Set<String>?) -> (items: [Item], seen: Set<String>) {
        let current = ids(nudges: nudges, notices: notices)
        guard let seen else { return ([], current) }

        var items: [Item] = []
        for nudge in nudges where !seen.contains("nudge:\(nudge.id)") {
            items.append(nudgeItem(nudge))
        }
        for notice in notices where !seen.contains("notice:\(notice.id)") {
            items.append(Item(id: "notice:\(notice.id)", title: appName(notice.app), body: notice.text))
        }

        if items.count > batchAbove {
            let summary = Item(
                id: "batch",
                title: "\(items.count) new things on BookMaster",
                body: "Open the Together tab to see them.")
            return ([summary], current)
        }
        return (items, current)
    }

    /// How a suggestion is told: who suggested what, and their note.
    static func nudgeItem(_ nudge: BMNudge) -> Item {
        let who = nudge.fromName.trimmingCharacters(in: .whitespaces)
        var body = nudge.title
        if let author = nudge.author, !author.isEmpty { body += " by \(author)" }
        if let note = nudge.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            body += " — “\(note)”"
        }
        return Item(
            id: "nudge:\(nudge.id)",
            title: who.isEmpty ? "A book suggestion" : "\(who) suggested a book",
            body: body)
    }

    /// Everything waiting, as the keys the "already told" set is made of.
    static func ids(nudges: [BMNudge], notices: [BMNotice]) -> Set<String> {
        Set(nudges.map { "nudge:\($0.id)" } + notices.map { "notice:\($0.id)" })
    }

    /// "quest-log" → "Quest Log"; the suite's own names are kept as written.
    static func appName(_ slug: String) -> String {
        switch slug {
        case "": return "BookMaster"
        case "bookmaster": return "BookMaster"
        case "kindred": return "Kindred"
        case "quest-log", "questlog": return "Quest Log"
        default:
            return slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
