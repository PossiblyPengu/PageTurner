import Foundation

/// A book's authors as one line: each person once, joined by " & " (a comma reads as "Last, First" to BookMaster).
/// Pure, so it is checked on Linux.
///
/// A book's own details often name one person more than once — an EPUB 2 creator beside an EPUB 3 one, "John doe" in
/// one place and "John Doe" in another, "Doe, John" beside "John Doe" — and every name was put on the line, so the
/// book read "John doe & John Doe".
enum AuthorNames {
    /// The names, each person once, in the order first given.
    static func joined(_ names: [String]) -> String {
        var kept: [(key: String, name: String)] = []
        for raw in names {
            let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let who = key(name)
            guard !who.isEmpty else { continue }
            if let i = kept.firstIndex(where: { $0.key == who }) {
                if better(name, than: kept[i].name) { kept[i].name = name }
            } else {
                kept.append((who, name))
            }
        }
        return kept.map(\.name).joined(separator: " & ")
    }

    /// An author line already joined (a book added before this, a catalogue's), with each person once. A line of one
    /// name is left exactly as it is.
    static func cleaned(_ line: String) -> String {
        let parts = line.components(separatedBy: " & ")
        guard parts.count > 1 else { return line }
        return joined(parts)
    }

    /// Who a name is: its letters and digits in any case and with any accents, and "Last, First" read as "First Last"
    /// (but not "King, Jr.").
    static func key(_ name: String) -> String {
        var name = name
        let halves = name.components(separatedBy: ",")
        if halves.count == 2 {
            let last = halves[0].trimmingCharacters(in: .whitespaces)
            let first = halves[1].trimmingCharacters(in: .whitespaces)
            if !last.isEmpty, !first.isEmpty, !suffixes.contains(fold(first)) { name = first + " " + last }
        }
        return fold(name)
    }

    private static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd", "md"]

    private static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Which of two spellings of one name to show: "First Last" over "Last, First"; then one written as a name is
    /// (each word with a capital) over one in lower case or in capitals; else the one met first.
    static func better(_ candidate: String, than kept: String) -> Bool {
        let candidateInverted = candidate.contains(","), keptInverted = kept.contains(",")
        if candidateInverted != keptInverted { return !candidateInverted }
        return casing(candidate) > casing(kept)
    }

    private static func casing(_ name: String) -> Int {
        let letters = name.filter(\.isLetter)
        guard !letters.isEmpty else { return 0 }
        if letters.allSatisfy(\.isLowercase) { return 0 }
        if letters.allSatisfy(\.isUppercase) { return 1 }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        return 2 + words.filter { $0.first?.isUppercase == true }.count
    }
}
