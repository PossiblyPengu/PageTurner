import Foundation

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

    /// What may go up: the draft trimmed, or nil when it is blank or too long.
    static func sendable(_ draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > maxLength ? nil : text
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
    static func replacingNewest(_ existing: [BMChatMessage], with page: [BMChatMessage]) -> [BMChatMessage] {
        guard let first = page.first else { return [] }
        return existing.filter { $0.id < first.id } + page
    }

    /// "Seen" under your last message once the other reader has read it,
    /// "Sent" until then. Nothing when there is nobody to read it.
    static func seenLabel(lastMineId: Int?, theirsRead: Int, hasPartner: Bool) -> String? {
        guard hasPartner, let id = lastMineId else { return nil }
        return id <= theirsRead ? "Seen" : "Sent"
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
