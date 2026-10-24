import Foundation

enum SpeechText {
    /// Cleaned for a voice: a book's typographic debris taken out, a few things said the way a
    /// reader says them. The rules are compiled once — this runs for every sentence of a book.
    static func spoken(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "ﬀ", with: "ff")
            .replacingOccurrences(of: "ﬁ", with: "fi")
            .replacingOccurrences(of: "ﬂ", with: "fl")
            .replacingOccurrences(of: "ﬃ", with: "ffi")
            .replacingOccurrences(of: "ﬄ", with: "ffl")

        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: nsRange(text), withTemplate: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // a running page number ("42", "- 42 -", "Page 42") is not part of the story — judged
        // before a roman heading numeral becomes digits, so "XLII" is still a chapter
        if AppPrefs.speechSkipsPageNumbers, isPageNumber(text) { return "" }
        text = romanNumerals(in: text)
        text = dates(in: text)
        return spaceBeforePunctuation.stringByReplacingMatches(in: text, range: nsRange(text), withTemplate: "$1")
    }

    /// Only digits (at most four), or "page" and digits, or those between dashes or brackets.
    static func isPageNumber(_ text: String) -> Bool {
        pageNumber.firstMatch(in: text, range: nsRange(text)) != nil
    }

    /// Whether two pieces the sentence tokenizer cut apart are really one sentence. A title or
    /// abbreviation at the end of the first never ends a sentence; a second piece that begins in
    /// lower case is the rest of the first; and across a printed line break, anything short of a
    /// full stop carries on. Spaces alone between two finished sentences keep them apart.
    static func shouldJoin(previous: String, separator: String, next: String) -> Bool {
        guard !separator.isEmpty, separator.allSatisfy(\.isWhitespace) else { return false }
        let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if abbreviationEnd.firstMatch(in: left, range: nsRange(left)) != nil { return true }
        if let first = right.first, first.isLowercase { return true }
        guard separator.contains(where: \.isNewline) else { return false }
        return sentenceEnd.firstMatch(in: left, range: nsRange(left)) == nil
    }

    /// The value of a roman numeral in its strict form (I to MMMCMXCIX), nil for anything else —
    /// "DID", "MIMIC" and "IIII" are not numerals.
    static func romanValue(_ text: String) -> Int? {
        guard !text.isEmpty, strictRoman.firstMatch(in: text, range: nsRange(text)) != nil else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = value
        }
        return total
    }

    /// Where a word the voice reported in `spoken` (what it was given, `spoken(original)`) is in
    /// `original` (the page's text, which the locator carries). Nil when the word has no
    /// counterpart — the "example" of an "e.g." spelled out, the "to" of a year range — and the
    /// caller falls back to the sentence. Cheap when nothing changed, which is most sentences.
    static func originalRange(of range: Range<String.Index>, spoken: String, original: String) -> Range<String.Index>? {
        let spokenWords = wordRanges(in: spoken)
        // a range that is no word (a comma, say) has no counterpart at all
        guard let k = spokenWords.firstIndex(where: { $0.overlaps(range) }) else { return nil }
        if spoken == original { return range }
        let originalWords = wordRanges(in: original)
        let target = folded(spoken[spokenWords[k]])
        // every rule that keeps the word count (ligatures, soft hyphens, spacing) keeps the order —
        // but only when the word itself survives ("e.g." becomes two other words by coincidence)
        if spokenWords.count == originalWords.count,
           folded(original[originalWords[k]]) == target { return originalWords[k] }
        guard !originalWords.isEmpty else { return nil }
        let guess = Int((Double(k) * Double(originalWords.count) / Double(spokenWords.count)).rounded())
        for distance in [0, 1, -1, 2, -2, 3, -3, 4, -4] {
            let i = guess + distance
            guard originalWords.indices.contains(i) else { continue }
            if folded(original[originalWords[i]]) == target { return originalWords[i] }
        }
        return nil
    }

    /// Runs of letters, digits and in-word apostrophes.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            // footnote marks (superscript digits) are cut from the spoken text, so they are not words of it
            let mark = c.unicodeScalars.allSatisfy { [0xB9, 0xB2, 0xB3, 0x2070].contains(Int($0.value)) || (0x2074 ... 0x2079).contains(Int($0.value)) }
            let inWord = !mark && (c.isLetter || c.isNumber || c == "'" || c == "’" || c == "\u{00AD}")
            if inWord, start == nil { start = index }
            if !inWord, let from = start { out.append(from ..< index); start = nil }
            index = text.index(after: index)
        }
        if let from = start { out.append(from ..< text.endIndex) }
        return out
    }

    /// A word as it compares: lower case, ligatures opened, soft hyphens and apostrophes gone.
    private static func folded(_ word: Substring) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "ﬀ", with: "ff").replacingOccurrences(of: "ﬁ", with: "fi")
            .replacingOccurrences(of: "ﬂ", with: "fl").replacingOccurrences(of: "ﬃ", with: "ffi")
            .replacingOccurrences(of: "ﬄ", with: "ffl")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    // MARK: Rules

    /// In order: a word hyphenated across a printed line is rejoined; runs of white space are one
    /// space; footnote markers (superscript digits, "[12]") go; abbreviations everyone says in full
    /// are spelled out, "etc." keeping the full stop when it ends the sentence; an en dash between
    /// numbers is "to".
    private static let rules: [(NSRegularExpression, String)] = [
        (rx(#"(?<=\p{Ll})[-‐‑]\s*\n\s*(?=\p{Ll})"#), ""),
        (rx(#"[\t\n\v\f ]+"#), " "),
        (rx(#"[\x{00B9}\x{00B2}\x{00B3}\x{2070}\x{2074}-\x{2079}]+"#), ""),
        (rx(#"\[\d{1,3}\]"#), ""),
        (rx(#"\b[eE]\.\s*[gG]\.(?=\s|$)"#), "for example"),
        (rx(#"\b[iI]\.\s*[eE]\.(?=\s|$)"#), "that is"),
        (rx(#"\b[vV][sS]\.(?=\s|$)"#), "versus"),
        (rx(#"\b[eE][tT][cC]\.(?=\s*$|\s+\p{Lu})"#), "et cetera."),
        (rx(#"\b[eE][tT][cC]\.(?=\s)"#), "et cetera"),
        (rx(#"(?<=\d)\s*–\s*(?=\d)"#), " to "),
    ]

    private static let spaceBeforePunctuation = rx(#"\s+([,;:.!?…])"#)
    private static let pageNumber = rx(#"^[\[(\-–—\s]*(?:page\s+)?\d{1,4}[\])\-–—\s]*$"#, [.caseInsensitive])
    private static let sentenceEnd = rx(#"[.!?…]["'”’)]*$"#)
    private static let abbreviationEnd = rx(
        #"\b(?:Mr|Mrs|Ms|Mx|Dr|Prof|Sr|Jr|St|Mt|Gen|Col|Capt|Lt|Sgt|Rev|Hon|Vol|Fig|Ch|cf|vs|e\.g|i\.e)\.["'”’)]*$"#,
        [.caseInsensitive])
    private static let strictRoman = rx(#"^M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})$"#)
    /// A numeral after a heading word ("Chapter XIV", "PART II") — the word's case is
    /// ignored but the numeral itself must be uppercase, so "Chapter xiv" stays a word.
    private static let headingNumeral = rx(
        #"\b(?i:Chapter|Part|Book|Volume|Vol\.|Section|Act|Scene|Canto|Letter|Stave)\s+([MDCLXVI]+)\b"#)
    private static let loneNumeral = rx(#"^([MDCLXVI]{2,})(\.?)$"#)

    /// Roman numerals a voice would spell out, written as numbers. "I" alone stays a pronoun.
    private static func romanNumerals(in text: String) -> String {
        if let match = loneNumeral.firstMatch(in: text, range: nsRange(text)),
           let numeral = Range(match.range(at: 1), in: text), let value = romanValue(String(text[numeral])) {
            let stop = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            return "\(value)\(stop)"
        }
        let matches = headingNumeral.matches(in: text, range: nsRange(text))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let numeral = Range(match.range(at: 1), in: out), let value = romanValue(String(out[numeral])) else { continue }
            out.replaceSubrange(numeral, with: String(value))
        }
        return out
    }

    // MARK: Dates

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordinals = [
        "", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
        "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
        "twentieth", "twenty-first", "twenty-second", "twenty-third", "twenty-fourth", "twenty-fifth", "twenty-sixth",
        "twenty-seventh", "twenty-eighth", "twenty-ninth", "thirtieth", "thirty-first",
    ]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
    private static let monthWord = "(?:January|February|March|April|May|June|July|August|September|October|November|December)"

    private static func below100(_ n: Int) -> String {
        n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10])
    }

    /// A year of the 1100s to 1900s as a person says it: "nineteen eighty-four", "eighteen oh five", "nineteen hundred".
    /// Nil for any other number — a voice reads those as they are.
    static func yearWords(_ year: Int) -> String? {
        guard (1100 ... 1999).contains(year) else { return nil }
        let high = year / 100, low = year % 100
        if low == 0 { return below100(high) + " hundred" }
        if low < 10 { return below100(high) + " oh " + ones[low] }
        return below100(high) + " " + below100(low)
    }

    /// "1990s" as "nineteen nineties", "2010s" as "twenty tens".
    static func decadeWords(_ year: Int) -> String? {
        guard year % 10 == 0, (1100 ... 2090).contains(year) else { return nil }
        if year == 2000 { return "two thousands" }
        let high = year / 100, low = year % 100
        if low == 0 { return below100(high) + " hundreds" }
        let tensWord = below100(low)
        let plural = tensWord.hasSuffix("y") ? String(tensWord.dropLast()) + "ies" : tensWord + "s"
        return below100(high) + " " + plural
    }

    private static let isoDate = rx(#"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    private static let slashDate = rx(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#)
    private static let monthAbbreviation = rx(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept?|Oct|Nov|Dec)\.?(?=\s+\d)"#)
    private static let monthYear = rx("\\b(\(monthWord))(\\s+\\d{1,2}(?:st|nd|rd|th)?,?)?(\\s+)(1[1-9]\\d\\d)\\b")
    private static let contextYear = rx(#"\b(in|In|of|since|until|by|from|during|year|circa|AD|A\.D\.)\s+(1[1-9]\d\d)\b"#)
    private static let yearRange = rx(#"\b(1[1-9]\d\d)(?:\s*[-‐‑]\s*|\s+to\s+)(1[1-9]\d\d)\b"#)
    private static let decade = rx(#"\b(1[1-9]\d0|20\d0)['’]?s\b"#)
    private static let shortDecade = rx(#"(?<![\p{L}\d])['’](\d)0s\b"#)

    /// Dates said the way they are read: "1984-05-12" and "5/12/1984" as "May twelfth, nineteen eighty-four", "Mar 5" as
    /// "March 5", a year after a month or "in" as words, "1914-1918" as a span, "1990s" as "nineteen nineties".
    private static func dates(in source: String) -> String {
        var text = source
        // quick exit: nothing here has a digit
        guard text.rangeOfCharacter(from: .decimalDigits) != nil else { return text }

        func replace(_ regex: NSRegularExpression, _ make: (NSTextCheckingResult, String) -> String?) {
            let matches = regex.matches(in: text, range: nsRange(text))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: text), let new = make(match, text) else { continue }
                text.replaceSubrange(whole, with: new)
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
            Range(match.range(at: index), in: source).map { String(source[$0]) } ?? ""
        }
        func year(_ y: Int) -> String { yearWords(y) ?? String(y) }
        func spokenDate(month: Int, day: Int, year y: Int) -> String? {
            guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
            return "\(monthNames[month - 1]) \(ordinals[day]), \(year(y))"
        }

        replace(yearRange) { m, t in
            guard let a = Int(group(m, 1, t)), let b = Int(group(m, 2, t)), b > a, b - a < 200 else { return nil }
            return "\(year(a)) to \(year(b))"
        }
        replace(isoDate) { m, t in
            guard let y = Int(group(m, 1, t)), let mo = Int(group(m, 2, t)), let d = Int(group(m, 3, t)) else { return nil }
            return spokenDate(month: mo, day: d, year: y)
        }
        replace(slashDate) { m, t in
            guard let a = Int(group(m, 1, t)), let b = Int(group(m, 2, t)), let y = Int(group(m, 3, t)) else { return nil }
            // the part that cannot be a month is the day; when both could be, the reader's region decides
            let dayFirst = a > 12 || (b <= 12 && Locale.current.region?.identifier != "US")
            return dayFirst ? spokenDate(month: b, day: a, year: y) : spokenDate(month: a, day: b, year: y)
        }
        let full = ["Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June", "Jul": "July",
                    "Aug": "August", "Sep": "September", "Sept": "September", "Oct": "October", "Nov": "November", "Dec": "December"]
        replace(monthAbbreviation) { m, t in full[group(m, 1, t)] }
        replace(monthYear) { m, t in
            guard let y = Int(group(m, 4, t)), let words = yearWords(y) else { return nil }
            return group(m, 1, t) + group(m, 2, t) + group(m, 3, t) + words
        }
        replace(contextYear) { m, t in
            guard let y = Int(group(m, 2, t)), let words = yearWords(y) else { return nil }
            return group(m, 1, t) + " " + words
        }
        replace(decade) { m, t in Int(group(m, 1, t)).flatMap(decadeWords) }
        replace(shortDecade) { m, t in
            guard let d = Int(group(m, 1, t)) else { return nil }
            return d == 0 ? "hundreds" : below100(d * 10).hasSuffix("y") ? String(below100(d * 10).dropLast()) + "ies" : below100(d * 10) + "s"
        }
        return text
    }

    private static func nsRange(_ text: String) -> NSRange {
        NSRange(text.startIndex ..< text.endIndex, in: text)
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // patterns are literals in this file; a bad one is a bug the Linux check catches
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
