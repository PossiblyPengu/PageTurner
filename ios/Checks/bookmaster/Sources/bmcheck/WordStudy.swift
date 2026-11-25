import Foundation

/// Saved words studied: a short definition read from Wiktionary's answer, and a review that brings each word back
/// less often the more times it has been known (boxes of 1, 3, 7, 16, 35 and 90 days). Pure, so it is checked on
/// Linux; the fetching is `WordDefinitions`.
enum WordStudy {
    /// How long a word known once, twice… stays away.
    static let intervals: [TimeInterval] = [1, 3, 7, 16, 35, 90].map { $0 * 86_400 }

    /// The longest a definition is kept: a line or two under the word.
    static let longestDefinition = 220

    /// Due for review: never reviewed, or its time has come.
    static func isDue(_ word: SavedWord, now: Date) -> Bool {
        (word.dueAt ?? .distantPast) <= now
    }

    /// The words to review now, longest waiting first (a word never reviewed waits from when it was saved), at most
    /// `limit` of them.
    static func due(_ words: [SavedWord], now: Date, limit: Int = 20) -> [SavedWord] {
        Array(words.filter { isDue($0, now: now) }
            .sorted { ($0.dueAt ?? $0.createdAt) < ($1.dueAt ?? $1.createdAt) }
            .prefix(limit))
    }

    /// `word` after a review: known, it moves up a box and stays away that box's time; not known, it starts again
    /// and is due at once.
    static func graded(_ word: SavedWord, knew: Bool, now: Date) -> SavedWord {
        var graded = word
        if knew {
            let box = min((word.box ?? 0) + 1, intervals.count)
            graded.box = box
            graded.dueAt = now.addingTimeInterval(intervals[box - 1])
        } else {
            graded.box = 0
            graded.dueAt = now
        }
        return graded
    }

    /// Known every time up to the last box: learned.
    static func isLearned(_ word: SavedWord) -> Bool { (word.box ?? 0) >= intervals.count }

    /// "adjective: Gloomy; dismal." — the first definitions of the first part of speech that has one, from
    /// Wiktionary's REST answer (`/page/definition/<word>`), in `language` when it has that, else English, else
    /// any. "" when the answer holds no definition (the word was looked for and is not there); nil when it is no
    /// such answer at all.
    static func definition(fromWiktionary data: Data, language: String? = nil) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let lists = object.compactMapValues { $0 as? [[String: Any]] }
        guard !lists.isEmpty else { return nil }
        let preferred = [language?.lowercased(), "en"].compactMap { $0 }
        let order = preferred.filter { lists[$0] != nil } + lists.keys.sorted().filter { !preferred.contains($0) }
        for code in order {
            for usage in lists[code] ?? [] {
                let senses = (usage["definitions"] as? [[String: Any]] ?? [])
                    .compactMap { $0["definition"] as? String }
                    .map(plain)
                    .filter { !$0.isEmpty }
                guard let first = senses.first else { continue }
                var text = first
                // a short first sense has room for the next
                if senses.count > 1, first.count < 60 { text += " " + senses[1] }
                if text.count > longestDefinition {
                    text = String(text.prefix(longestDefinition - 1))
                    if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
                    text += "…"
                }
                let part = (usage["partOfSpeech"] as? String)?.lowercased() ?? ""
                return part.isEmpty ? text : "\(part): \(text)"
            }
        }
        return ""
    }

    /// Wiktionary's address for a word: its spaces as underscores, the rest escaped.
    static func wiktionaryPath(for word: String) -> String? {
        let name = word.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: "_")
        guard !name.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return name.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func plain(_ html: String) -> String {
        BookText.plain(fromHTML: html)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
