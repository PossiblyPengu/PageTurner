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

    private static func nsRange(_ text: String) -> NSRange {
        NSRange(text.startIndex ..< text.endIndex, in: text)
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // patterns are literals in this file; a bad one is a bug the Linux check catches
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
