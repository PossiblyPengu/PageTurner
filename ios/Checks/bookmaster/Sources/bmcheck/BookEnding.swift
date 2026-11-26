import Foundation

/// When a book is finished, and what is said about it then. Pure, so it is checked on Linux.
///
/// A book read to its last page used to stay at 99%: the place saved is where the page *starts*, and the last page
/// starts short of the end. And many books end in what is not the story — acknowledgements, "About the Author", a
/// preview of the next book — so a reader done with the story stopped at 92%. Now the end counts as reached when the
/// bottom of what is on the page reaches the end of the story (`showsEnd`): the end of the book, or the start of the
/// back matter that closes it (`storyEnd`).
enum BookEnding {
    /// Contents entries that come after the story: words that are a title's whole word, and phrases it contains.
    private static let backMatterWords: Set<String> = [
        "acknowledgments", "acknowledgements", "acknowledgment", "acknowledgement", "index", "bibliography",
        "endnotes", "glossary", "colophon", "copyright", "credits", "permissions", "excerpt", "preview", "newsletter",
        "teaser",
    ]
    private static let fillers: Set<String> = ["the", "a", "an", "end", "closing", "opening", "general", "page"]
    private static let connectors: Set<String> = ["of", "from", "for", "to", "and", "in"]
    private static let backMatterPhrases = [
        "about the author", "about the authors", "about the illustrator", "about the translator", "about the publisher",
        "also by", "also available", "other books by", "other titles", "books by", "by the same author", "more from",
        "more books", "praise for", "sneak peek", "coming soon", "keep reading", "read on", "reading group",
        "discussion questions", "questions for discussion", "book club", "a conversation with", "interview with",
        "sign up", "thank you for reading", "dear reader", "don't miss", "dont miss", "what to read next",
        "a note on the type",
    ]

    /// Whether a contents entry is back matter — after the story, and not part of it.
    static func isBackMatter(_ title: String) -> Bool {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
        let words = folded.split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !words.isEmpty else { return false }
        if words == ["notes"] || words == ["end", "notes"] { return true }
        // a back-matter word leads the title, alone or before "of", "from", "and"… — "Copyright Page", "End Credits",
        // "Index of Names", "Excerpt from Book Two" — but "The Index Card" is a chapter
        let core = words.filter { !fillers.contains($0) }
        if let first = core.first, backMatterWords.contains(first) {
            if core.count == 1 || connectors.contains(core[1]) { return true }
            if core.allSatisfy({ backMatterWords.contains($0) || connectors.contains($0) }) { return true }
        }
        let spaced = words.joined(separator: " ")
        return backMatterPhrases.contains { spaced.contains($0) }
    }

    /// Where the story ends: the start of the run of back matter that closes the contents (every entry after it back
    /// matter too), in the entries' own measure, running to `end`. Nil when the contents end with the story — and when
    /// the back matter would be half the book or more (titles read wrong, not a book that is mostly appendix).
    static func storyEnd(_ entries: [(title: String, start: Double)], end: Double = 1) -> Double? {
        let ordered = entries.sorted { $0.start < $1.start }
        guard let last = ordered.lastIndex(where: { !isBackMatter($0.title) }), last + 1 < ordered.count else { return nil }
        let start = ordered[last + 1].start
        guard start.isFinite, start >= end * 0.5, start < end else { return nil }
        return start
    }

    /// Whether the page shows the end: the bottom of what is on screen (Readium's viewport, 0…1) has reached the end of
    /// the story, give or take a hair.
    static func showsEnd(visibleUpTo upper: Double, storyEnd: Double?) -> Bool {
        upper.isFinite && upper >= (storyEnd ?? 1) - 0.0005
    }

    /// How far back from the end of the story a finished book may be read and stay finished — a look at the last
    /// chapter again; further back is reading it again.
    static let finishedReach = 0.05

    /// An audiobook's share heard: all of it in the closing credits (`storyEnd`, seconds) or the last half minute,
    /// else the position over the length.
    static func heardShare(position: Double, duration: Double, storyEnd: Double?) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        if let storyEnd, position >= storyEnd - 1 { return 1 }
        if duration - position <= 30 { return 1 }
        return min(max(position / duration, 0), 1)
    }

    // MARK: What is said at the end

    /// The time a book took, from its sittings.
    struct Summary: Equatable {
        let minutes: Double
        let sittings: Int
        let days: Int
        let started: Date

        /// "6 h 12 min over 9 days · 14 sittings".
        var line: String {
            let time = Self.duration(minutes)
            let over = days > 1 ? " over \(days) days" : ""
            let count = sittings == 1 ? "1 sitting" : "\(sittings) sittings"
            return "\(time)\(over) · \(count)"
        }

        static func duration(_ minutes: Double) -> String {
            let whole = Int(minutes.rounded())
            if whole < 60 { return "\(max(whole, 1)) min" }
            let h = whole / 60, m = whole % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
    }

    /// The book's sittings summed; nil with under a minute of them.
    static func summary(of sessions: [ReadingSession], book: UUID, calendar: Calendar = .current) -> Summary? {
        let own = sessions.filter { $0.bookID == book && $0.minutes > 0 }
        let minutes = own.reduce(0) { $0 + $1.minutes }
        guard minutes >= 1, let first = own.map({ $0.end.addingTimeInterval(-$0.minutes * 60) }).min() else { return nil }
        let days = Set(own.map { calendar.startOfDay(for: $0.end) }).count
        return Summary(minutes: minutes, sittings: own.count, days: days, started: first)
    }

    /// Other books by the same author in the library not yet finished — the ones not started first — leaving out the
    /// book's other edition.
    static func moreBy(_ book: Book, in books: [Book], limit: Int = 3) -> [Book] {
        guard !book.author.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let others = books.filter { other in
            other.id != book.id && !other.author.isEmpty && (other.progression ?? 0) < 0.995
                && other.textVersionOf == nil
                && (BMShelf.authorsAgree(book.author, other.author) || BMShelf.authorsAgree(other.author, book.author))
                && !BMShelf.titlesAgree(book.title, other.title)
        }
        return Array(others.sorted { a, b in
            let startedA = (a.progression ?? 0) > 0.001, startedB = (b.progression ?? 0) > 0.001
            if startedA != startedB { return !startedA }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }.prefix(limit))
    }
}
