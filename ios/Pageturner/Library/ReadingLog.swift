import Foundation

/// The sittings kept on this device — what the Stats tab shows without BookMaster.
/// A small JSON file in Application Support; BookMaster gets its own copy of each
/// sitting through the sync path, this one never leaves the phone.
@MainActor
final class ReadingLog: ObservableObject {
    static let shared = ReadingLog()

    @Published private(set) var sessions: [ReadingSession] = []

    /// Sittings older than this are dropped when the log is saved.
    private static let keepDays = 800
    /// A sitting is wall-clock time with the book open; a book left open on the
    /// nightstand shouldn't count for the night.
    private static let longestSession = 6.0 * 60

    private let url: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("reading-log.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let list = try? decoder.decode([ReadingSession].self, from: data) {
            sessions = list
        }
    }

    var stats: ReadingStats { ReadingStats.compute(sessions) }

    /// Note a finished sitting. Anything under six seconds is a tap, not reading.
    /// The bounds are finite-checked too: one NaN in a stored session makes every
    /// later encode of the whole log fail — the sitting is lost, not the log.
    func record(book: Book, minutes: Double, from start: Double, to end: Double, audio: Bool, at date: Date = Date()) {
        guard AppPrefs.statsTracking, minutes.isFinite, minutes >= 0.1, start.isFinite, end.isFinite else { return }
        sessions.append(ReadingSession(
            bookID: book.id, title: book.title, end: date,
            minutes: min(minutes, Self.longestSession),
            progressStart: start, progressEnd: end, audio: audio))
        save()
    }

    func clear() {
        sessions = []
        save()
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        sessions.removeAll { $0.end < cutoff }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try encoder.encode(sessions).write(to: url, options: .atomic)
        } catch {
            Log.error("reading-log", "save failed: \(error.localizedDescription)")
        }
    }
}
