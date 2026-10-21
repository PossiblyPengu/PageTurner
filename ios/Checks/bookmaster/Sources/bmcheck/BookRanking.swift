import Foundation

/// Putting search results in the order a reader means.
///
/// Open Library ranks by its own relevance, which weighs popularity and
/// edition counts over how well a title answers the words typed. Measured on
/// real searches it put the wrong book first often enough to matter: "the
/// women kristin hannah" led with The Nightingale, "onyx storm" with a
/// three-book box set and a work filed under its Spanish title, "Alas de
/// ónix".
///
/// Ported line for line from BookMaster's `shared/ranking.ts`, so a result
/// lands in the same place whichever app made the call.
enum BookRank {
    /// Words that carry no weight in a title or a query.
    private static let stopwords: Set<String> = ["a", "an", "the", "of", "and", "by", "to", "in", "on", "for", "s"]

    /// Words that mark an omnibus rather than the book itself.
    private static let bundle =
        #"\b(box(ed)?[\s-]?set|collection set|books? set|\d+[\s-]books?|omnibus|bundle|trilogy set|series set)\b"#
    private static let bundleQuery = #"\b(box|set|collection|omnibus|bundle|trilogy|series)\b"#

    /// Study aids and companions that ride on a bestseller's title: "Summary
    /// of Educated…", "Project Hail Mary Summary", "After Reading Project Hail
    /// Mary", "…Ultimate Movie Guide". Apple lists a great many.
    private static let studyAid =
        #"\b(summary|summaries|study guide|analysis|workbook|sparknotes|cliffsnotes|quicklet|movie guide|reader'?s guide|after reading|unofficial)\b"#
    private static let studyQuery = #"\b(summary|study|guide|analysis|workbook|notes|companion|unofficial)\b"#

    /// A title that names its own author — "Project Hail Mary By Andy Weir" —
    /// is, when the author field says someone else ("Easy Reads"), a knock-off
    /// riding on the real book. Two or more capitalised words after "by", so
    /// "Death by Chocolate" and "Stand By Me" are left alone.
    private static func namesAnotherAuthor(_ title: String, _ author: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"\bby\s+((?:[A-Z][\w.'-]*\s*){2,})$"#),
              let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let r = Range(m.range(at: 1), in: trimmed)
        else { return false }
        let named = tokens(String(trimmed[r]))
        let actual = Set(tokens(author))
        return !named.isEmpty && !named.allSatisfy { actual.contains($0) }
    }

    /// The meaningful words of a title, author or query, folded for comparison.
    static func tokens(_ value: String) -> [String] {
        BookMatch.fold(value).split(separator: " ").map(String.init).filter { !stopwords.contains($0) }
    }

    /// An ISBN typed as the whole query: nothing to rank by words.
    static func isIsbnQuery(_ query: String) -> Bool {
        let digits = query.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
        return BookMatch.matches(#"^(\d{9}[\dXx]|\d{13})$"#, in: digits)
    }

    /// The fewest single-letter edits — an insertion, a deletion, a
    /// substitution or two neighbours swapped — that turn one word into the
    /// other, giving up past `max`. Swaps count once, so "tolkein" is one slip
    /// from "tolkien".
    static func editDistance(_ a: String, _ b: String, max: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max + 1 }
        if abs(a.count - b.count) > max { return max + 1 }
        var prev2 = [Int]()
        var prev = Array(0 ... b.count)
        for i in 1 ... a.count {
            var row = [i]
            var smallest = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var d = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d = min(d, prev2[j - 2] + 1)
                }
                row.append(d)
                smallest = min(smallest, d)
            }
            if smallest > max { return max + 1 }
            prev2 = prev
            prev = row
        }
        return prev[b.count]
    }

    /// How well one typed word answers one word of a title or a name: 1 for
    /// the word itself; a little less for a slip of the keys ("forth" for
    /// fourth, "poter", "kristen" for Kristin) — one edit from five letters,
    /// two from eight — or, for the word still being typed, the start of one
    /// ("thro"); 0 otherwise. Short words must be exact: "wing" is not "king".
    static func wordMatch(typed: String, word: String, typing: Bool = false) -> Double {
        if typed == word { return 1 }
        if typing, typed.count >= 3, word.hasPrefix(typed) { return 0.9 }
        let slack = typed.count >= 8 ? 2 : typed.count >= 5 ? 1 : 0
        return slack > 0 && editDistance(typed, word, max: slack) <= slack ? 0.85 : 0
    }

    /// The query's words, once each; the last is the one that may still be
    /// being typed.
    private static func queryWords(_ query: String) -> (words: [String], typing: (Int) -> Bool) {
        var seen = Set<String>()
        let words = tokens(query).filter { seen.insert($0).inserted }
        // A trailing space means the last word is finished.
        let open = query.range(of: #"\s$"#, options: .regularExpression) == nil
        return (words, { open && $0 == words.count - 1 })
    }

    /// How well any of the query's words answers one word of a title or name.
    private static func answered(_ word: String, _ q: (words: [String], typing: (Int) -> Bool)) -> Double {
        var best = 0.0
        for (i, typed) in q.words.enumerated() {
            best = max(best, wordMatch(typed: typed, word: word, typing: q.typing(i)))
        }
        return best
    }

    /// Whether the query holds the lead author's whole name, in order —
    /// "kristin hannah", "sarah j maas". Typed together like that, the words
    /// ask for that writer's books rather than for any title that shares one
    /// of them.
    private static func namesTheAuthor(
        _ q: (words: [String], typing: (Int) -> Bool), _ author: String
    ) -> Bool {
        var lead = author
        if let r = lead.range(of: #",|&| and "#, options: [.regularExpression, .caseInsensitive]) {
            lead = String(lead[..<r.lowerBound])
        }
        let name = tokens(lead)
        guard name.count >= 2, q.words.count >= name.count else { return false }
        for start in 0 ... (q.words.count - name.count) {
            if name.enumerated().allSatisfy({ k, w in
                wordMatch(typed: q.words[start + k], word: w, typing: q.typing(start + k)) > 0
            }) {
                return true
            }
        }
        return false
    }

    /// How well a title and author answer a query, from 0 to about 2.5.
    ///
    /// Two halves: how much of the title the query names (so the book whose
    /// title is exactly what was typed beats one that merely shares a word),
    /// and how much of the query the title and author explain (so a query that
    /// includes the author favours that author's book). Words match through a
    /// typo, and the last one before it is finished. An author's whole name,
    /// typed together, lifts their books above titles that happen to share a
    /// word with it. A box set or a study guide is marked down unless the
    /// query asked for one, and so is a title too long to be anything but a
    /// catalogue oddity — a seventeenth-century pamphlet that happens to
    /// contain "forth".
    static func relevance(title: String, author: String, query: String) -> Double {
        let q = queryWords(query)
        if q.words.isEmpty { return 0 }
        let t = tokens(title)
        let a = tokens(author)
        let titleCovered = t.isEmpty ? 0 : t.reduce(0) { $0 + answered($1, q) } / Double(t.count)
        var explained = 0.0
        for (i, typed) in q.words.enumerated() {
            var best = 0.0
            for w in t + a { best = max(best, wordMatch(typed: typed, word: w, typing: q.typing(i))) }
            explained += best
        }
        explained /= Double(q.words.count)
        let authorBonus = namesTheAuthor(q, author) ? 0.8 : 0
        let bundlePenalty = BookMatch.matches(bundle, in: title) && !BookMatch.matches(bundleQuery, in: query) ? 0.8 : 0
        let studyPenalty = (BookMatch.matches(studyAid, in: title) && !BookMatch.matches(studyQuery, in: query))
            || namesAnotherAuthor(title, author) ? 0.8 : 0
        // A record with no author is almost always a stub — no cover, no year —
        // sitting beside the real one; it goes below the books that have one.
        let stubPenalty = author.trimmingCharacters(in: .whitespaces).isEmpty
            || author.trimmingCharacters(in: .whitespaces).lowercased() == "unknown" ? 0.8 : 0
        let longPenalty = t.count > 20 ? 0.5 : 0
        return titleCovered + explained + authorBonus - bundlePenalty - studyPenalty - stubPenalty - longPenalty
    }

    /// The query as it was probably meant, spelled from words a catalogue has
    /// just returned for it — or nil when it already reads right.
    ///
    /// Open Library matches words exactly, so "forth wing" finds pamphlets
    /// that set something forth, and "kristen hannah" finds a Kristen who
    /// wrote about a Hannah. Apple's search forgives the slip, and its titles
    /// and authors carry the words meant: each typed word they do not contain
    /// is swapped for the nearest one they do ("forth" → "fourth"), and a word
    /// still being typed is finished ("thro" → "throne"). Nothing is swapped
    /// for a word that is not there; short words are left alone.
    static func correctQuery(_ query: String, found: [(title: String, author: String)]) -> String? {
        var counts: [String: Int] = [:]
        for f in found {
            for w in tokens(f.title) + tokens(f.author) {
                counts[w, default: 0] += 1
            }
        }
        if counts.isEmpty { return nil }
        let words = BookMatch.fold(query).split(separator: " ").map(String.init)
        let open = query.range(of: #"\s$"#, options: .regularExpression) == nil
        var changed = false
        let fixed = words.enumerated().map { i, typed -> String in
            if typed.count < 3 || stopwords.contains(typed) || counts[typed] != nil
                || typed.allSatisfy(\.isNumber) {
                return typed
            }
            let typing = open && i == words.count - 1
            var best: (word: String, score: Double, count: Int)?
            for (word, count) in counts {
                let score = wordMatch(typed: typed, word: word, typing: typing)
                if score == 0 { continue }
                if best == nil || score > best!.score || (score == best!.score && count > best!.count) {
                    best = (word, score, count)
                }
            }
            guard let best else { return typed }
            changed = true
            return best.word
        }
        return changed ? fixed.joined(separator: " ") : nil
    }

    /// A box set, a study aid or a knock-off riding on another book's title —
    /// never worth suggesting, whatever it was searched for.
    static func isRider(title: String, author: String) -> Bool {
        BookMatch.matches(bundle, in: title) || BookMatch.matches(studyAid, in: title)
            || namesAnotherAuthor(title, author)
    }

    /// A result as ranking sees it: enough to score and to spot a duplicate.
    protocol Rankable {
        var title: String { get }
        var author: String { get }
        var coverUrl: String? { get set }
        var totalPages: Int? { get set }
        var publishedYear: Int? { get set }
    }

    /// Same book, found twice: title, plus the lead author's first initial and
    /// surname — enough to keep Frank and Brian Herbert's Dunes apart while
    /// "J.K. Rowling" and "J. K. Rowling" still read as one person.
    private static func identity(_ book: some Rankable) -> String {
        var lead = book.author
        if let r = lead.range(of: #",|&| and "#, options: [.regularExpression, .caseInsensitive]) {
            lead = String(lead[..<r.lowerBound])
        }
        let name = tokens(lead)
        let who = name.isEmpty ? "" : "\(name[0].prefix(1))|\(name[name.count - 1])"
        return "\(tokens(book.title).joined(separator: " "))|\(who)"
    }

    /// Order results by how well they answer the query, and fold duplicates.
    ///
    /// Results that score alike keep the catalogue's own order, which still
    /// carries its popularity signal. A duplicate lends whatever it has that
    /// the first copy lacks — a cover, a page count, a year — before it is
    /// dropped. An ISBN query is left in the catalogue's order; there are no
    /// words to rank. `meant` is the query as corrected (see `correctQuery`):
    /// a result scores by whichever of the two it answers better.
    static func rankResults<T: Rankable>(_ results: [T], query: String, meant: String? = nil) -> [T] {
        if isIsbnQuery(query) { return results }

        var seen: [String: Int] = [:]
        var unique: [T] = []
        for book in results {
            let key = identity(book)
            if let at = seen[key] {
                if unique[at].coverUrl == nil { unique[at].coverUrl = book.coverUrl }
                if unique[at].totalPages == nil { unique[at].totalPages = book.totalPages }
                if unique[at].publishedYear == nil { unique[at].publishedYear = book.publishedYear }
            } else {
                seen[key] = unique.count
                unique.append(book)
            }
        }

        let scored = unique.enumerated().map { item -> (book: T, index: Int, score: Double) in
            let book = item.element
            let direct = relevance(title: book.title, author: book.author, query: query)
            let fixed = meant.map { relevance(title: book.title, author: book.author, query: $0) } ?? 0
            return (book: book, index: item.offset, score: max(direct, fixed))
        }
        // Scores this close are a tie: keep the catalogue's order between
        // them. The index tiebreak makes the sort strict.
        return scored
            .sorted { abs($0.score - $1.score) > 0.05 ? $0.score > $1.score : $0.index < $1.index }
            .map(\.book)
    }

    /// The best-matching edition Open Library returns alongside a work.
    struct EditionHint {
        var title: String?
        var coverI: Int?
        var languages: [String]? = nil
    }

    /// Which title and cover to show for a work.
    ///
    /// Open Library files a work under the title — and shows the cover — of
    /// whichever edition created it, so an English bestseller can surface as
    /// "Alas de ónix", or as "The Women" wearing the Spanish "Las Mujeres de
    /// la Guerra" cover. It also returns the edition that best matches the
    /// search.
    ///
    /// Title: the edition's, when it answers the query better; otherwise the
    /// work's own. Cover: the edition's when its title was the one chosen (so
    /// the two agree) or when the search was an ISBN (then it is the very
    /// edition asked for); otherwise the work's. Not simply "any English
    /// edition": set side by side over twenty searches, that swapped in
    /// special editions, large-print printings and decades-old paperbacks
    /// about as often as it fixed a wrong one. The search prefers Apple's
    /// publisher art where it has it.
    static func preferEdition(
        work: (title: String, coverI: Int?),
        edition: EditionHint?,
        author: String,
        query: String
    ) -> (title: String, coverI: Int?) {
        guard let edition else { return work }
        let isbn = isIsbnQuery(query)
        let useTitle = edition.title != nil && !isbn
            && relevance(title: edition.title!, author: author, query: query)
                > relevance(title: work.title, author: author, query: query) + 0.05
        let useCover = edition.coverI != nil && (useTitle || isbn)
        if !useTitle && !useCover { return work }
        return (useTitle ? edition.title! : work.title, useCover ? edition.coverI : work.coverI)
    }
}
