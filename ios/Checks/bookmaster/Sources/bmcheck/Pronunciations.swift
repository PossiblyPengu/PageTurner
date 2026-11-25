import Foundation

/// A word the reader taught the voice: "Hermione" said "her-MY-oh-nee". For every book, or for one.
struct Pronunciation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The word as the book prints it — one word or a few ("Daenerys", "Minas Tirith").
    var written: String
    /// What the voice is given in its place.
    var said: String
    /// The book it is for; nil for every book.
    var bookID: UUID?

    init(id: UUID = UUID(), written: String, said: String, bookID: UUID? = nil) {
        self.id = id
        self.written = written
        self.said = said
        self.bookID = bookID
    }
}

/// The words the voice has been taught, put in what it is given to say (`SpeechText.spoken`). Pure, so it is
/// checked on Linux.
///
/// A taught word is put in last, after the rest of the cleaning, and where it went is kept (`Respelled`) so the
/// marks on the page still land on the word as printed: the first word of what is said stands for it, and the
/// rest follow it (`SpeechText.WordMap`). The engines read this off the main actor, so it is behind a lock.
enum Pronunciations {
    /// Where a taught word was put in the text the voice is given: the range of what is said instead, and the
    /// words as they were written (a "’s" after it included).
    struct Respelled: Sendable {
        let said: Range<String.Index>
        let written: String
    }

    /// The most words an entry may have, and the most letters: a pronunciation is for a name or a word, not a
    /// passage.
    static let maxWords = 4
    static let maxLength = 60

    /// Teach the voice `entries`: every book's, then `book`'s own, which win over them.
    static func use(_ entries: [Pronunciation], book: UUID?) {
        var table: [String: String] = [:]
        var written: [String: String] = [:]
        let ordered = entries.filter { $0.bookID == nil } + entries.filter { $0.bookID != nil && $0.bookID == book }
        for entry in ordered {
            guard let word = cleaned(entry.written) else { continue }
            let said = entry.said.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !said.isEmpty else { continue }
            table[key(word)] = said
            written[key(word)] = word
        }
        var matcher: NSRegularExpression?
        if !written.isEmpty {
            // the longest first, so "Minas Tirith" is found before "Minas"; spaces in an entry match any run of them
            let alternatives = written.values
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
                .map { word in
                    word.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                        .joined(separator: #"\s+"#)
                }
            let pattern = #"(?<![\p{L}\p{N}'’])("# + alternatives.joined(separator: "|") + #")(['’]s)?(?![\p{L}\p{N}])"#
            matcher = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        state.lock.lock()
        state.table = table
        state.matcher = matcher
        state.generation += 1
        state.lock.unlock()
    }

    /// Changes every time `use` is called — a cache of cleaned text keyed on it is never stale.
    static var generation: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.generation
    }

    /// `text` with each taught word put as it is said, and where each went.
    static func respell(_ text: String) -> (text: String, respelled: [Respelled]) {
        state.lock.lock()
        let matcher = state.matcher
        let table = state.table
        state.lock.unlock()
        guard let matcher, !table.isEmpty, !text.isEmpty else { return (text, []) }
        let ns = text as NSString
        let matches = matcher.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }

        var out = ""
        // where each went, in UTF-16 offsets into `out` (an index into a string being appended to is not kept)
        var places: [(from: Int, to: Int, written: String)] = []
        var last = 0
        for match in matches {
            let word = ns.substring(with: match.range(at: 1))
            guard let said = table[key(word)] else { continue }
            let suffixRange = match.range(at: 2)
            let suffix = suffixRange.location == NSNotFound ? "" : ns.substring(with: suffixRange)
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let from = out.utf16.count
            out += said + suffix
            places.append((from, out.utf16.count, word + suffix))
            last = match.range.location + match.range.length
        }
        guard !places.isEmpty else { return (text, []) }
        out += ns.substring(from: last)
        let respelled = places.map { place in
            Respelled(
                said: String.Index(utf16Offset: place.from, in: out) ..< String.Index(utf16Offset: place.to, in: out),
                written: place.written)
        }
        return (out, respelled)
    }

    /// A word or a few as an entry keeps them: spaces closed up, nil when there is nothing to teach or too much
    /// (more than `maxWords` words, longer than `maxLength`, or no letter in it).
    static func cleaned(_ written: String) -> String? {
        let words = written.split(whereSeparator: \.isWhitespace)
        let word = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'’-")))
        guard !word.isEmpty, words.count <= maxWords, word.count <= maxLength, word.contains(where: \.isLetter)
        else { return nil }
        return word
    }

    /// Two spellings of an entry are one when they differ only in case, spacing or the kind of apostrophe.
    static func key(_ written: String) -> String {
        written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var table: [String: String] = [:]
        var matcher: NSRegularExpression?
        var generation = 0
    }

    private static let state = State()
}
