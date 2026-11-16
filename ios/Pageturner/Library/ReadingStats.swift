import Foundation

/// One sitting with a book, kept on this device whether or not BookMaster is linked.
struct ReadingSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookID: UUID
    var title: String
    /// When the sitting ended.
    var end: Date
    var minutes: Double
    /// 0…1 through the book at either end.
    var progressStart: Double
    var progressEnd: Double
    var audio: Bool
}

/// Totals, streaks and a daily chart worked out from the sittings. Pure logic —
/// a `Calendar` and "now" are passed in so the day boundaries can be checked.
struct ReadingStats: Equatable {
    struct Day: Equatable, Identifiable {
        /// Start of the day.
        var date: Date
        var minutes: Double
        var id: Date { date }
    }

    struct BookTotal: Equatable, Identifiable {
        var bookID: UUID
        var title: String
        var minutes: Double
        var audio: Bool
        var id: UUID { bookID }
    }

    var minutesToday = 0.0
    var minutesLast7Days = 0.0
    var minutesTotal = 0.0
    var sessionCount = 0
    /// Days in a row up to today — or up to yesterday, while today hasn't started yet.
    var currentStreak = 0
    var longestStreak = 0
    /// The last `days` days, oldest first, today last.
    var daily: [Day] = []
    /// Most time first.
    var perBook: [BookTotal] = []

    /// A day counts towards a streak with at least this many minutes.
    static let streakMinutes = 1.0

    static func compute(
        _ sessions: [ReadingSession], now: Date = Date(), calendar: Calendar = .current, days: Int = 14
    ) -> ReadingStats {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: offset, to: date) ?? date }

        var perDay: [Date: Double] = [:]
        var books: [UUID: BookTotal] = [:]
        var stats = ReadingStats()
        for session in sessions where session.minutes > 0 && session.minutes.isFinite {
            perDay[calendar.startOfDay(for: session.end), default: 0] += session.minutes
            stats.minutesTotal += session.minutes
            stats.sessionCount += 1
            var total = books[session.bookID] ?? BookTotal(bookID: session.bookID, title: session.title, minutes: 0, audio: session.audio)
            total.minutes += session.minutes
            total.title = session.title   // the most recent name wins
            books[session.bookID] = total
        }

        stats.minutesToday = perDay[today] ?? 0
        stats.minutesLast7Days = (0..<7).reduce(0) { $0 + (perDay[day(-$1, from: today)] ?? 0) }
        stats.daily = (0..<max(days, 0)).reversed().map { back in
            let date = day(-back, from: today)
            return Day(date: date, minutes: perDay[date] ?? 0)
        }
        stats.perBook = books.values.sorted {
            $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.title < $1.title
        }

        // streaks run over the days that count
        let active = Set(perDay.filter { $0.value >= streakMinutes }.keys)
        var cursor = active.contains(today) ? today : day(-1, from: today)
        while active.contains(cursor) {
            stats.currentStreak += 1
            cursor = day(-1, from: cursor)
        }
        var run = 0
        var previous: Date?
        for date in active.sorted() {
            if let previous, day(1, from: previous) == date { run += 1 } else { run = 1 }
            stats.longestStreak = max(stats.longestStreak, run)
            previous = date
        }
        return stats
    }

    /// "1h 05m", "42m", "0m".
    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total <= 0 { return "0m" }
        return total >= 60 ? String(format: "%dh %02dm", total / 60, total % 60) : "\(total)m"
    }
}

/// A finish-date forecast from the same sittings. Pure, like `ReadingStats`: a `Calendar` and "now" come in so the day
/// boundaries can be checked.
enum ReadingTrends {
    struct Forecast: Equatable {
        var daysLeft: Int
        var finish: Date
    }

    /// When a book will be done at the pace of the last three weeks: how much of it was read, spread over the days
    /// since the first of those sittings (a few days off count against the pace, the way they would for the reader).
    /// Nil with fewer than two sittings, no progress, or a finish further than a year away.
    static func forecast(
        _ sessions: [ReadingSession], bookID: UUID, progress: Double, now: Date = Date(), calendar: Calendar = .current
    ) -> Forecast? {
        guard progress.isFinite, progress >= 0, progress < 0.995 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let since = calendar.date(byAdding: .day, value: -21, to: today) else { return nil }
        let recent = sessions.filter {
            $0.bookID == bookID && $0.end >= since && $0.end <= now.addingTimeInterval(86_400)
        }
        guard recent.count >= 2 else { return nil }

        // going back to re-read something is not progress
        let gained = recent.reduce(0.0) { $0 + max(0, $1.progressEnd - $1.progressStart) }
        guard gained >= 0.005 else { return nil }
        guard let first = recent.map({ calendar.startOfDay(for: $0.end) }).min() else { return nil }
        let span = max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)

        let perDay = gained / Double(span)
        let days = Int(((1 - progress) / perDay).rounded(.up))
        guard days >= 1, days <= 365, let finish = calendar.date(byAdding: .day, value: days, to: today) else { return nil }
        return Forecast(daysLeft: days, finish: finish)
    }

    /// "Done around Oct 22 at this pace", or "Done by tomorrow…", "Done in about 3 days…".
    static func label(_ forecast: Forecast) -> String {
        switch forecast.daysLeft {
        case 1: return "Done by tomorrow at this pace"
        case 2 ... 6: return "Done in about \(forecast.daysLeft) days at this pace"
        default: return "Done around \(forecast.finish.formatted(.dateTime.month(.abbreviated).day())) at this pace"
        }
    }
}
