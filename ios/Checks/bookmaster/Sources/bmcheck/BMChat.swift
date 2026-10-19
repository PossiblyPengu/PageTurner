import Foundation

/// The two rooms the chat screen holds: the shared one, and Quest Log's own (`BMQuestLog`).
enum BMChatTab: String, CaseIterable, Identifiable {
    case us, questLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: return "Us"
        case .questLog: return "Quest Log"
        }
    }
}

/// The suite's shared chat, apart from any screen: how a run of messages is
/// laid out, what may be sent, how a page of messages folds into what is
/// already shown, and what "Seen" says. BookMaster's `chatView.ts` lays out
/// its web page the same way, so the two read alike.
enum BMChat {
    /// The server's limit on one message.
    static let maxLength = 2000
    /// Messages from one person this close together read as one burst.
    static let burst: TimeInterval = 5 * 60
    /// The feed carries one notice with this prefix while anything is unread.
    static let noticePrefix = "bookmaster:chat:"

    /// The notice that says a message is waiting, if one is.
    static func unreadNotice(_ notices: [BMNotice]) -> BMNotice? {
        notices.first { $0.id.hasPrefix(noticePrefix) }
    }

    /// The same, unless it is the one already opened: a newer message carries a new notice id, so its
    /// dot comes back on its own.
    static func unread(_ notices: [BMNotice], seen: String?) -> BMNotice? {
        guard let notice = unreadNotice(notices), notice.id != seen else { return nil }
        return notice
    }

    /// What may go up: the draft trimmed, or nil when it is blank or too long. The server counts
    /// UTF-16 units (what a JavaScript string's length is), so this does too: an emoji is two, a family
    /// emoji eleven — counting what a reader sees as one character would let through what it refuses.
    static func sendable(_ draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.utf16.count > maxLength ? nil : text
    }

    /// Whether the draft is over the limit, for saying so (a blank one is not).
    static func isTooLong(_ draft: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > maxLength
    }

    /// How many messages one request returns.
    static let pageSize = 60

    /// The notices that are Quest Log's.
    static func questLogNotices(_ notices: [BMNotice]) -> [BMNotice] {
        notices.filter { BMSuite.dotTone(forApp: $0.app) == .questLog }
    }

    /// Whether Quest Log has something not yet looked at: a notice whose id has not been seen. (Quest Log
    /// never says what, and its room is its own, so opening the room is what counts as looking.)
    static func questLogUnseen(_ notices: [BMNotice], seen: Set<String>) -> Bool {
        questLogNotices(notices).contains { !seen.contains($0.id) }
    }

    /// Messages in id order, once each. Where both lists hold an id, the
    /// incoming copy wins.
    static func merge(_ existing: [BMChatMessage], _ incoming: [BMChatMessage]) -> [BMChatMessage] {
        var byId: [Int: BMChatMessage] = [:]
        for m in existing { byId[m.id] = m }
        for m in incoming { byId[m.id] = m }
        return byId.values.sorted { $0.id < $1.id }
    }

    /// The newest page, fetched again: it replaces everything from its first
    /// message on — so a message the other reader took back disappears —
    /// while older messages loaded earlier stay. An empty page is an empty room.
    ///
    /// When a whole page arrives and does not reach back to anything already held, more than a page
    /// came in between looks (a long time away): what is held is no longer joined to it, so only the
    /// page is kept — "Earlier messages" then pages back from there, with nothing silently missing.
    static func replacingNewest(
        _ existing: [BMChatMessage], with page: [BMChatMessage], pageSize: Int = BMChat.pageSize
    ) -> [BMChatMessage] {
        guard let first = page.first else { return [] }
        if page.count >= pageSize, let newest = existing.last, newest.id < first.id { return page }
        return existing.filter { $0.id < first.id } + page
    }

    /// "Seen" under your last message once the other reader has read it,
    /// "Sent" until then. Nothing when there is nobody to read it.
    static func seenLabel(lastMineId: Int?, theirsRead: Int, hasPartner: Bool) -> String? {
        guard hasPartner, let id = lastMineId else { return nil }
        return id <= theirsRead ? "Seen" : "Sent"
    }

    /// What to tell the reader when a send or a take-back fails: the server's own words where they
    /// help, and what to do where the link itself has broken.
    static func explain(_ error: Error) -> String {
        if case let BMError.server(code, message) = error {
            if code == 404, message == "Unknown reader" {
                return "BookMaster no longer recognises this device. Link it again in Settings."
            }
            if let message, !message.isEmpty { return message }
            return code == 429 ? "Slow down a little — too many messages at once." : "BookMaster answered \(code)."
        }
        return "Couldn’t reach BookMaster. Try again in a moment."
    }

    /// Where a message was written, when that is not here.
    static func via(_ app: String) -> String? {
        app == "pageturner" ? nil : BMSuite.names[app]
    }

    struct Row: Identifiable, Equatable {
        var message: BMChatMessage
        /// "Today", "Yesterday", a weekday, a date — on the first message of each day.
        var day: String?
        /// First of a burst: carries the name.
        var head: Bool
        /// Last of a burst: carries the time.
        var tail: Bool
        var id: Int { message.id }
    }

    /// A day label where the day changes, a name where the speaker does.
    static func rows(
        _ messages: [BMChatMessage], now: Date = Date(),
        calendar: Calendar = .current, locale: Locale = .current
    ) -> [Row] {
        func continues(_ a: BMChatMessage?, _ b: BMChatMessage) -> Bool {
            guard let a else { return false }
            return a.userId == b.userId
                && b.date.timeIntervalSince(a.date) < burst
                && calendar.isDate(a.date, inSameDayAs: b.date)
        }
        return messages.enumerated().map { i, m in
            let prev = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let newDay = prev.map { !calendar.isDate($0.date, inSameDayAs: m.date) } ?? true
            let endsBurst = next.map { !continues(m, $0) } ?? true
            return Row(
                message: m,
                day: newDay ? dayLabel(m.date, now: now, calendar: calendar, locale: locale) : nil,
                head: !continues(prev, m),
                tail: endsBurst)
        }
    }

    /// "Today", "Yesterday", the weekday inside a week, else the date.
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMMy")
        }
        return f.string(from: date)
    }

    /// A clock time, in the reader's own locale.
    static func clock(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
