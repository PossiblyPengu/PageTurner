import Foundation

/// The ebook and the audiobook of one book, kept together: which book in the library is the other edition, and the
/// same place in it — the chapter of the same name and as far into it, or failing that the same share of the
/// whole. Pure, so it is checked on Linux.
///
/// The two editions rarely have the same chapters: an ebook has a title page and a dedication, an audiobook
/// opening credits, and either may name its chapters "Chapter 3", "Three" or "III". So chapters are matched by a
/// folded name (`chapterKey`), and where several match, the one nearest the same share of the book wins.
enum Companion {
    /// A place, as either edition can find it in itself.
    struct Place: Equatable, Sendable {
        /// The chapter it is in, as that edition names it; nil without chapters.
        var chapter: String?
        /// How far into that chapter, 0…1.
        var fraction: Double
        /// How far through the whole book, 0…1.
        var overall: Double
    }

    /// Where a chapter starts, in its edition's own measure (seconds of an audiobook, the share of an ebook).
    struct Mark: Equatable, Sendable {
        let title: String
        let start: Double
    }

    /// The other edition of `book` in `books`: an audiobook for an ebook and an ebook for an audiobook, with the same
    /// title and authors that agree. The one with the very same title over one that only agrees; then the one opened
    /// last. Nil when there is none.
    static func match(for book: Book, in books: [Book]) -> Book? {
        let candidates = books.filter { other in
            other.id != book.id && other.isAudio != book.isAudio && other.textVersionOf == nil
                && BMShelf.titlesAgree(book.title, other.title)
                // either way round: one side may be "Weir, Andy"
                && (BMShelf.authorsAgree(book.author, other.author) || BMShelf.authorsAgree(other.author, book.author))
        }
        let title = fold(book.title)
        return candidates.max { a, b in
            let sameA = fold(a.title) == title, sameB = fold(b.title) == title
            if sameA != sameB { return !sameA }
            return (a.lastOpenedAt ?? .distantPast) < (b.lastOpenedAt ?? .distantPast)
        }
    }

    /// The place at `position` among `marks` (in order) of an edition that runs to `end`.
    static func place(at position: Double, in marks: [Mark], end: Double) -> Place {
        guard end > 0, position.isFinite else { return Place(chapter: nil, fraction: 0, overall: 0) }
        let at = min(max(position, 0), end)
        let overall = at / end
        guard let i = marks.lastIndex(where: { $0.start <= at + 0.000001 }) else {
            return Place(chapter: nil, fraction: 0, overall: overall)
        }
        let start = marks[i].start
        let next = i + 1 < marks.count ? marks[i + 1].start : end
        let fraction = next > start ? min(max((at - start) / (next - start), 0), 1) : 0
        return Place(chapter: marks[i].title, fraction: fraction, overall: overall)
    }

    /// Where `place` is in an edition with `marks` running to `end`: as far into the chapter of the same name, or,
    /// with none of that name, the same share of the whole.
    static func locate(_ place: Place, in marks: [Mark], end: Double) -> Double {
        let fallback = min(max(place.overall, 0), 1) * end
        guard end > 0, let chapter = place.chapter else { return fallback }
        let want = chapterKey(chapter).split(separator: " ").map(String.init)
        guard !want.isEmpty else { return fallback }
        let found = marks.indices.filter { i in
            let have = chapterKey(marks[i].title).split(separator: " ").map(String.init)
            guard !have.isEmpty else { return false }
            // the same name, or one ending the other ("Dune: Chapter 3" and "Chapter 3")
            return have == want || have.ends(with: want) || want.ends(with: have)
        }
        // several of that name (a "Prologue" to each part): the one nearest the same share of the book
        guard let i = found.min(by: { abs(marks[$0].start / end - place.overall) < abs(marks[$1].start / end - place.overall) })
        else { return fallback }
        let start = marks[i].start
        let next = i + 1 < marks.count ? marks[i + 1].start : end
        return start + min(max(place.fraction, 0), 1) * max(next - start, 0)
    }

    /// A chapter's name as both editions might give it: lower case without accents or punctuation, a leading track
    /// number gone, "chapter" dropped, and numbers in words or roman numerals as digits — "Chapter Three",
    /// "03 - Chapter 3" and "III" all "3".
    static func chapterKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // a track number before the name: "03 - Chapter 3", "01 Prologue"
        if words.count > 1, words[0].allSatisfy(\.isNumber) { words.removeFirst() }
        words.removeAll { $0 == "chapter" || $0 == "ch" || $0 == "chap" }
        words = joinedNumberWords(words)
        if words.count == 1, let value = roman(words[0]) { words = [String(value)] }
        // "03" and "3" are one
        words = words.map { word in word.allSatisfy(\.isNumber) ? String(Int(word) ?? 0) : word }
        return words.joined(separator: " ")
    }

    // MARK: -

    private static func fold(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// "twenty one" (the hyphen already split) → "21", "three" → "3"; other words as they are.
    private static func joinedNumberWords(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            if let ten = tens[word] {
                if i + 1 < words.count, let unit = units[words[i + 1]], unit < 10 {
                    out.append(String(ten + unit))
                    i += 2
                    continue
                }
                out.append(String(ten))
            } else if let unit = units[word] {
                out.append(String(unit))
            } else {
                out.append(word)
            }
            i += 1
        }
        return out
    }

    /// A roman numeral up to 89 (a chapter's), strictly formed; nil for anything else.
    private static func roman(_ word: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50]
        guard !word.isEmpty, word.count <= 7, word.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0, previous = 0
        for character in word.reversed() {
            let value = values[character]!
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        // only the strict spelling of its value counts ("iiii", "vx" are not numerals)
        return total > 0 && total < 90 && romanSpelling(total) == word ? total : nil
    }

    private static func romanSpelling(_ n: Int) -> String {
        let table: [(Int, String)] = [(50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, out = ""
        for (value, letters) in table {
            while n >= value { out += letters; n -= value }
        }
        return out
    }
}

private extension Array where Element: Equatable {
    func ends(with tail: [Element]) -> Bool {
        tail.count <= count && Array(suffix(tail.count)) == tail
    }
}
