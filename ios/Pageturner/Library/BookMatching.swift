import Foundation

/// Deciding whether a catalogue record is the book we asked about.
///
/// Every metadata source answers a query it cannot satisfy with whatever it
/// considers closest rather than with nothing, so results have to be checked
/// instead of trusted in order. This is BookMaster's `shared/matching.ts`
/// ported line for line, so a cover chosen here is chosen on exactly the
/// same terms as one chosen there. Pure Foundation so the Linux checks run it.
enum BookMatch {
    /// Reduce a title or a name to the part worth comparing.
    ///
    /// Goodreads titles carry series notes — "Ender's Game (Ender's Saga, #1)" —
    /// that other catalogues do not, and any two sources may differ in accents,
    /// case or punctuation. Stripping all of that leaves words to compare.
    static func fold(_ value: String) -> String {
        // NFD, then the combining marks out — "Alas de ónix" folds beside "onix".
        var scalars = String.UnicodeScalarView()
        for scalar in value.decomposedStringWithCanonicalMapping.unicodeScalars
        where !(0x300 ... 0x36F).contains(Int(scalar.value)) {
            scalars.append(scalar)
        }
        var s = String(scalars).lowercased()
        s = s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        // Apostrophes are dropped rather than spaced out, so that "Ender's
        // Game" folds to "enders game" and not to "ender s game".
        s = s.replacingOccurrences(of: #"['‘’]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static let wordNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// The first capture group of `pattern` in `s`, when it matches.
    private static func group(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }

    /// Whether `pattern` matches anywhere in `s`.
    static func matches(_ pattern: String, in s: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Which volume of a series a title refers to, if it says.
    ///
    /// Three shapes turn up: Goodreads' "(Zodiac Academy, #5)", a spelled-out
    /// "Volume Four", and Open Library's habit of ending the title with the
    /// bare number, as in "Zodiac Academy 5".
    static func volumeOf(_ title: String) -> Int? {
        if let hash = group(#"#(\d+)"#, in: title) { return Int(hash) }

        if let vol = group(#"\bvol(?:ume)?\.?\s+(\d+|[a-z]+)\b"#, in: title, options: [.caseInsensitive]) {
            let raw = vol.lowercased()
            if let n = Int(raw) { return n }
            if let n = wordNumbers[raw] { return n }
        }

        let bare = title.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let trailing = group(#"\s(\d{1,2})$"#, in: bare) { return Int(trailing) }
        return nil
    }

    /// Whether a candidate is the same volume as the book asked about.
    ///
    /// Series records are the one place a title check is not enough. Open
    /// Library holds a single "Tales from the Gas Station", and it matched all
    /// four volumes on a real shelf — so three of them would have been handed
    /// the wrong artwork with full confidence. A record carrying no number is
    /// taken to be the first volume, which is what it invariably turns out to
    /// be.
    static func volumesAgree(_ want: String, _ got: String) -> Bool {
        guard let a = volumeOf(want) else { return true }
        guard let b = volumeOf(got) else { return a <= 1 }
        return a == b
    }

    /// The phrasings worth trying for a title, best first.
    ///
    /// A catalogue is not a search engine: an over-specified title matches
    /// nothing rather than matching loosely. Measured against a real shelf,
    /// asking for "Tales from the Gas Station: Volume One" returned nothing
    /// while "Tales from the Gas Station" returned four records — and a series
    /// volume is often filed under the series name and its number rather than
    /// its own title, which shares no words at all with what Goodreads calls
    /// it.
    static func titleQueries(_ title: String) -> [String] {
        var out: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !out.contains(trimmed) { out.append(trimmed) }
        }

        let bare = bareTitle(title)
        add(bare)
        add(String(bare.split(separator: ":").first ?? ""))
        // Some titles carry the alternative after a comma rather than a colon —
        // "The Hobbit, or There and Back Again" is catalogued as just "The
        // Hobbit".
        add(String(bare.split(separator: ",").first ?? ""))

        if let m = try? NSRegularExpression(pattern: #"\(([^,)#]+?)[,\s]*#([\d.]+)\)"#)
            .firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let series = Range(m.range(at: 1), in: title),
           let number = Range(m.range(at: 2), in: title) {
            add("\(title[series].trimmingCharacters(in: .whitespaces)) \(title[number])")
        }

        return out
    }

    /// A title with its series note removed, which is what to search on.
    static func bareTitle(_ title: String) -> String {
        let stripped = title
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }

    /// Whether two titles name the same book.
    ///
    /// Editions disagree about subtitles — "Dune" against "Dune: Book One" — so
    /// a whole-word prefix counts, but only when the shorter title is long
    /// enough to mean something. Without that floor, "It" would match half the
    /// catalogue.
    static func titlesMatch(_ want: String, _ got: String) -> Bool {
        let a = fold(want), b = fold(got)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 8 && long.hasPrefix(short + " ")
    }

    /// Split a credit that names several people into the individual names.
    ///
    /// Open Library returns authors as an array; Apple returns "Caroline
    /// Peckham & Susanne Valenti" in one string, and reading that whole phrase
    /// as a single name puts the surname at "Valenti" and loses the co-author
    /// entirely.
    static func splitAuthors(_ credit: String) -> [String] {
        credit
            .replacingOccurrences(of: #"\s*&\s*|\s+and\s+"#, with: "\u{1}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A name reduced to a first initial and a surname.
    ///
    /// Enough to let "J.R.R. Tolkien" meet "J. R. R. Tolkien" without keeping a
    /// list of initial spellings, while still separating relatives who write in
    /// the same series — Brian Herbert is not Frank Herbert, and a surname on
    /// its own would happily hand one of them the other's cover.
    private static func nameKey(_ value: String) -> String? {
        let parts = fold(value).split(separator: " ").map(String.init)
        guard let first = parts.first, let last = parts.last else { return nil }
        return "\(first.prefix(1)) \(last)"
    }

    /// Whether any of a record's credited authors is the one we are looking for.
    static func authorsMatch(_ want: String, _ credits: [String]) -> Bool {
        guard let a = nameKey(want) else { return false }
        return credits.contains { credit in
            splitAuthors(credit).contains { nameKey($0) == a }
        }
    }
}
