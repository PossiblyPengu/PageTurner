import Foundation

/// The story up to the reader's place, and who someone in it is, as Apple's on-device model is asked them
/// (`StoryTeller`): the text cut where the reader is, in pieces the model can take, the passages that name someone,
/// and what the model is told. Nothing past the reader's place is ever given to it, so nothing it says can give the
/// book away. Pure, so it is checked on Linux.
enum StoryRecap {
    /// The most text one request carries: the model's window is about 4,000 tokens for everything — what it is told,
    /// the text and its answer — and a token is about four letters of English.
    static let pieceLength = 7_000

    /// Bumped when what the model is asked changes, so recaps kept from before are made again.
    static let version = 1

    /// `text` up to `fraction` of it, ended after the last sentence before that point.
    static func upTo(_ fraction: Double, of text: String) -> String {
        guard fraction.isFinite else { return "" }
        if fraction >= 1 { return text }
        let count = Int(Double(text.count) * max(fraction, 0))
        guard count > 0 else { return "" }
        let cut = String(text.prefix(count))
        guard let end = lastSentenceEnd(in: cut) else { return cut }
        return String(cut[..<end])
    }

    /// `text` in pieces of at most `limit` characters, cut between paragraphs where it can, else after a sentence,
    /// else anywhere.
    static func pieces(of text: String, limit: Int = pieceLength) -> [String] {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var out: [String] = []
        while !rest.isEmpty {
            if rest.count <= limit {
                out.append(String(rest))
                break
            }
            let window = rest.prefix(limit)
            // past the first half of the window: a cut too early makes a crumb of a piece
            let half = window.index(window.startIndex, offsetBy: limit / 2)
            let cut = window[half...].range(of: "\n\n", options: .backwards)?.upperBound
                ?? window[half...].range(of: "\n", options: .backwards)?.upperBound
                ?? lastSentenceEnd(in: window[half...])
                ?? window.endIndex
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            rest = rest[cut...].drop { $0.isWhitespace }
        }
        return out
    }

    /// The sentences that name `name` — as a whole word or words, in any case — from `chapters` in order: the first
    /// few, where the reader met them, and then the latest, at most `limit` in all, each with its chapter. A name of
    /// several words found too seldom whole is looked for by its words as well ("Ned" for "Ned Stark").
    static func mentions(of name: String, in chapters: [(title: String, text: String)], limit: Int = 30) -> [String] {
        let words = name.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" }).map(String.init)
        guard !words.isEmpty else { return [] }
        var found = matching([words.joined(separator: " ")], in: chapters)
        if found.count < 3, words.count > 1 {
            // a lone word counts only when it is a name's: three letters or more, written with a capital
            let parts = words.filter { $0.count >= 3 && ($0.first?.isUppercase ?? false) }
            if !parts.isEmpty { found = matching(parts, in: chapters) }
        }
        guard found.count > limit else { return found }
        let early = limit / 3
        return Array(found.prefix(early)) + Array(found.suffix(limit - early))
    }

    // MARK: What the model is told

    static let recapInstructions = """
        You summarize parts of a novel for someone who has just read them and wants to remember what happened. \
        Write plainly, in the past tense, saying who did what. Use only what the text says: never guess at what \
        comes next or explain what it means. No introduction and no heading.
        """

    static func chapterPrompt(book: String, chapter: String, text: String, partial: Bool) -> String {
        let which = partial ? "the part the reader has read so far of \(chapter)" : chapter
        return "Summarize \(which) of “\(book)” in two or three sentences.\n\n\(text)"
    }

    static func joinPrompt(chapter: String, parts: [String]) -> String {
        "These summarize, in order, the parts of one chapter, \(chapter). Join them into one summary of two or three "
            + "sentences.\n\n" + parts.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The whole story from the chapters' recaps — the latest kept whole when they are too many for one request.
    static func storyPrompt(book: String, recaps: [(chapter: String, summary: String)]) -> String {
        var lines = recaps.map { "\($0.chapter): \($0.summary)" }
        var dropped = false
        while lines.joined(separator: "\n").count > pieceLength, lines.count > 1 {
            lines.removeFirst()
            dropped = true
        }
        let lead = dropped ? "Here are summaries of the latest chapters of “\(book)” the reader has read, in order."
            : "Here are summaries of the chapters of “\(book)” the reader has read, in order."
        return lead + " Tell the story so far in one paragraph of four to six sentences, keeping to what they say.\n\n"
            + lines.joined(separator: "\n")
    }

    static let whoInstructions = """
        You help a reader remember the people in a book they are part way through. Answer only from the passages \
        you are given, which are all the reader has read about the person so far, and never add anything they do not \
        say. Answer in two or three sentences. If the passages do not make clear who it is, say so in one sentence.
        """

    static func whoPrompt(name: String, book: String, passages: [String]) -> String {
        "Who is \(name) in “\(book)”, from these passages?\n\n" + passages.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: -

    private static func matching(_ phrases: [String], in chapters: [(title: String, text: String)]) -> [String] {
        let alternatives = phrases.map { phrase in
            phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        guard let rx = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive])
        else { return [] }
        var out: [String] = []
        for chapter in chapters {
            for sentence in sentences(in: chapter.text) {
                let ns = sentence as NSString
                guard rx.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                let short = sentence.count > 320 ? String(sentence.prefix(317)) + "…" : sentence
                out.append("(\(chapter.title)) \(short)")
            }
        }
        return out
    }

    /// The text's sentences, spaces closed up: cut after . ! ? or … (and a closing quote), and at line breaks.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previousEnds = false
        for character in text {
            if character.isNewline {
                flush(&current, into: &out)
                previousEnds = false
                continue
            }
            if previousEnds, character.isWhitespace {
                flush(&current, into: &out)
                previousEnds = false
                continue
            }
            current.append(character)
            if ".!?…".contains(character) {
                previousEnds = true
            } else if previousEnds, "\"”’)'".contains(character) {
                previousEnds = true
            } else {
                previousEnds = false
            }
        }
        flush(&current, into: &out)
        return out
    }

    private static func flush(_ current: inout String, into out: inout [String]) {
        let sentence = current.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !sentence.isEmpty { out.append(sentence) }
        current = ""
    }

    /// Just past the last ". " "! " "? " (or the same before a closing quote) in `text`.
    private static func lastSentenceEnd<S: StringProtocol>(in text: S) -> S.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            let before = text.index(before: index)
            if index < text.endIndex, text[index].isWhitespace, ".!?…\"”’".contains(text[before]) {
                // a quote counts only after a stop
                if "\"”’".contains(text[before]) {
                    guard before > text.startIndex, ".!?…".contains(text[text.index(before: before)]) else {
                        index = before
                        continue
                    }
                }
                return index
            }
            index = before
        }
        return nil
    }
}
