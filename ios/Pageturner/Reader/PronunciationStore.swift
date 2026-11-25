import Foundation

/// The words the reader has taught the voice (`Pronunciations`), kept in the app's preferences and handed to the
/// voice for the book it is reading — every book's entries, and that book's own over them.
@MainActor
final class PronunciationStore: ObservableObject {
    static let shared = PronunciationStore()

    @Published private(set) var entries: [Pronunciation] = []
    /// The book the voice is reading, whose own entries win over every book's.
    private var book: UUID?
    private static let key = "speech-pronunciations"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Pronunciation].self, from: data)
        {
            entries = saved
        }
        apply()
    }

    /// The voice is reading `book` now (`ReadAloud.begin`).
    func reading(_ book: UUID?) {
        guard book != self.book else { return }
        self.book = book
        apply()
    }

    /// The entry `book` hears for `written`: its own if it has one, else every book's.
    func entry(for written: String, book: UUID?) -> Pronunciation? {
        let key = Pronunciations.key(written)
        if let book, let own = entries.first(where: { $0.bookID == book && Pronunciations.key($0.written) == key }) {
            return own
        }
        return entries.first { $0.bookID == nil && Pronunciations.key($0.written) == key }
    }

    /// Keep `entry`, over the one with its id and over another for the same word and book. Nothing is kept for a
    /// word `Pronunciations.cleaned` refuses or an empty "say it like".
    func save(_ entry: Pronunciation) {
        guard let written = Pronunciations.cleaned(entry.written) else { return }
        let said = entry.said.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !said.isEmpty else { return }
        var kept = entry
        kept.written = written
        kept.said = said
        let key = Pronunciations.key(written)
        entries.removeAll { $0.id == kept.id || ($0.bookID == kept.bookID && Pronunciations.key($0.written) == key) }
        entries.append(kept)
        entries.sort { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        apply()
    }

    private func apply() {
        Pronunciations.use(entries, book: book)
    }
}
