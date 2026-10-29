import Charts
import SwiftUI

/// The pieces the three BookMaster tabs share: the card their sections are
/// drawn on, the prompt an unlinked tab stands on, the cover a shelf row
/// carries, and the small formatters the numbers all spell the same way.
extension View {
    /// A grouped-list card — the shape every BookMaster section takes.
    func bmCard() -> some View {
        padding(18)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
    }
}

/// A notification dot: round and in the accent for the suite, blue and square for Quest Log (see `BMDotTone`).
struct BMDot: View {
    let tone: BMDotTone
    var size: CGFloat = 9
    /// A ring in the colour of what it sits on, so a dot over an icon stays clear of it.
    var ring: Color?

    var body: some View {
        shape
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shape: some View {
        switch tone {
        case .regular:
            Circle().fill(Color.ptAccent)
                .overlay { if let ring { Circle().stroke(ring, lineWidth: 1.5) } }
        case .questLog:
            let corner = size * 0.28
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.blue)
                .overlay {
                    if let ring { RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(ring, lineWidth: 1.5) }
                }
        }
    }
}

/// What a BookMaster tab shows before an account is linked: the pitch, the
/// way in, and the device's own numbers — reading time is kept either way.
struct BMLinkPrompt: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var readingLog = ReadingLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ptAccent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your reading life, together")
                    .font(.title2.bold())
                Text("Link BookMaster to bring your shelf, streaks, goals, quotes and the other reader into Pageturner.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Progress follows you between devices", systemImage: "arrow.triangle.2.circlepath")
                Label("Goals, streaks and your year in books", systemImage: "chart.bar.fill")
                Label("A shared shelf and chat with your reading partner", systemImage: "person.2.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button { router.showLink = true } label: {
                Label("Link BookMaster", systemImage: "link")
                    .frame(maxWidth: .infinity)
                    // hug the button's edges at giant text instead of breaking mid-title
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.75)
            }
            .buttonStyle(.borderedProminent)
            .tint(.ptAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bmCard()

        BMDeviceCard()
    }
}

/// The phone's own numbers — private to this device, shown linked or not.
struct BMDeviceCard: View {
    @ObservedObject private var readingLog = ReadingLog.shared

    var body: some View {
        let stats = readingLog.stats
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On this iPhone").font(.headline)
                Text("Private to this device").font(.caption).foregroundStyle(.secondary)
            }
            if readingLog.sessions.isEmpty {
                Text("Reading and listening time will appear here after your first session.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    BMMetric(value: BMFormat.duration(minutes: Int(stats.minutesToday)),
                             label: "today", icon: "sun.max.fill", color: .orange)
                    Divider().frame(height: 48)
                    BMMetric(value: BMFormat.duration(minutes: Int(stats.minutesLast7Days)),
                             label: "last 7 days", icon: "calendar", color: .blue)
                    Divider().frame(height: 48)
                    BMMetric(value: "\(stats.currentStreak)",
                             label: "day streak", icon: "flame.fill", color: .orange)
                }
            }
        }
        .bmCard()
    }
}

/// The fuller on-device picture an unlinked Stats tab still earns: the week's
/// trend, the eight-week chart, and the books that took the most time — all
/// from the phone's own `ReadingLog`, like `BMDeviceCard` next door.
struct BMDeviceStatsCard: View {
    @ObservedObject private var readingLog = ReadingLog.shared

    var body: some View {
        let trends = ReadingTrends.summary(readingLog.sessions)
        let stats = readingLog.stats
        if !readingLog.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Trends").font(.headline)
                HStack(spacing: 0) {
                    BMMetric(value: BMFormat.duration(minutes: Int(trends.thisWeekMinutes)),
                             label: weekDelta(trends), icon: "chart.bar.fill", color: .ptAccent)
                    Divider().frame(height: 48)
                    BMMetric(value: "\(trends.activeDays)",
                             label: "days read, last 30", icon: "calendar", color: .blue)
                    Divider().frame(height: 48)
                    BMMetric(value: BMFormat.duration(minutes: Int(trends.averageActiveDayMinutes)),
                             label: "a reading day", icon: "clock.fill", color: .orange)
                }
                Chart(trends.weeks) { week in
                    BarMark(
                        x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Minutes", week.minutes))
                        .foregroundStyle(Color.ptAccent)
                        .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    }
                }
                .frame(height: 110)
                .accessibilityLabel("Minutes read per week, last \(trends.weeks.count) weeks")
            }
            .bmCard()

            if !stats.perBook.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Most time").font(.headline)
                    ForEach(stats.perBook.prefix(5)) { total in
                        HStack(spacing: 10) {
                            Image(systemName: total.audio ? "headphones" : "book.closed")
                                .foregroundStyle(Color.ptAccent)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text(total.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ReadingStats.duration(minutes: total.minutes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .bmCard()
            }
        }
    }

    /// "this week" or "this week, up 25%" — the caption under the week's total.
    private func weekDelta(_ trends: ReadingTrends.Summary) -> String {
        guard let change = trends.changeFromLastWeek, abs(change) >= 0.05 else { return "this week" }
        return "this week, \(change > 0 ? "up" : "down") \(Int((abs(change) * 100).rounded()))%"
    }
}

/// One number over a caption — the dashboard metric every card shares.
struct BMMetric: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A shelf row's jacket — the stored cover, else a quiet placeholder.
struct BMCover: View {
    let row: BMShelfRow
    var body: some View {
        // The box is decided here (2:3 of the width offered); RemoteCover only
        // ever fills what it is given, so a jacket's own size never leaks into
        // the grid's row heights.
        RemoteCover(urls: row.coverURLs, icon: row.isAudio ? "headphones" : "book.closed")
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Shared spelling for the things several screens write.
enum BMFormat {
    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func goalLabel(_ type: String) -> String {
        BMGoal.Kind(rawValue: type)?.label
            ?? type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
