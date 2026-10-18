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
            Button { router.showLink = true } label: {
                Label("Link BookMaster", systemImage: "link")
                    .frame(maxWidth: .infinity)
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
        // The box is decided here (2:3 of the width offered); the art only ever
        // fills it. AsyncImage otherwise lets a loaded file's intrinsic size
        // leak into the grid's row heights, so covers land different sizes.
        GeometryReader { geo in
            AsyncImage(url: row.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15).overlay(
                        Image(systemName: row.isAudio ? "headphones" : "book.closed")
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
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
