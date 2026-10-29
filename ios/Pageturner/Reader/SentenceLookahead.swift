import Foundation
import ReadiumNavigator
import ReadiumShared

/// The sentence after the one being read aloud, found the way read-aloud itself splits a book into
/// sentences — so a neural voice can start making it while the current one is still being said, and
/// the two follow each other without a gap.
///
/// It keeps the sentences of the paragraph being read (and the one after it, once asked), so most
/// questions are answered from memory; a skip or a jump to somewhere else starts it again from there.
@MainActor
final class SentenceLookahead {
    struct Sentence {
        let text: String
        let locator: Locator
        /// Nil unless it is in another language than the book.
        let language: Language?
    }

    private let publication: Publication
    private let tokenizer: ContentTokenizer
    private var iterator: ContentIterator?
    /// The sentences of the element the one being read is in…
    private var paragraph: [Sentence] = []
    /// …and of the element after it, once that has been needed.
    private var following: [Sentence]?
    /// One question at a time: the iterator is a single cursor.
    private var busy = false

    init(publication: Publication) {
        self.publication = publication
        tokenizer = makeReadingTokenizer(publication.metadata.language)
    }

    /// The sentence that follows `current`, or nil at the end of the book (or when this is busy answering
    /// another question — the caller just goes without).
    func sentence(after current: PublicationSpeechSynthesizer.Utterance) async -> Sentence? {
        await sentences(after: current, count: 1).first
    }

    /// The `count` sentences that follow `current`, in order — fewer at the book's end, none
    /// there (or while this is busy answering another question).
    func sentences(after current: PublicationSpeechSynthesizer.Utterance, count: Int) async -> [Sentence] {
        guard !busy, count > 0 else { return [] }
        busy = true
        defer { busy = false }

        // The same place in the book first, in this paragraph and then the next, and only then the same
        // words: a paragraph that says "No." after one that says "No." would otherwise be taken for it.
        var at = Self.index(of: current, in: paragraph, exact: true)
        if at == nil, let next = following, let i = Self.index(of: current, in: next, exact: true) {
            // read-aloud has moved on into the next paragraph
            paragraph = next
            following = nil
            at = i
        }
        if at == nil { at = Self.index(of: current, in: paragraph, exact: false) }
        if at == nil, let next = following, let i = Self.index(of: current, in: next, exact: false) {
            paragraph = next
            following = nil
            at = i
        }
        if at == nil {
            // the first question, or a skip or a jump: begin again from here
            let found = await restart(at: current)
            Self.log("restart \(found ? "found" : "did not find") the sentence; paragraph has \(paragraph.count)")
            guard found else { return [] }
            at = Self.index(of: current, in: paragraph)
        }
        guard let at else { return [] }
        // from the rest of this paragraph, then the start of the next that has any
        var out: [Sentence] = []
        var i = at + 1
        while out.count < count {
            if i < paragraph.count {
                out.append(paragraph[i])
            } else {
                if following == nil { following = await nextElement() }
                guard let next = following, i - paragraph.count < next.count else { return out }
                out.append(next[i - paragraph.count])
            }
            i += 1
        }
        return out
    }

    // MARK: Walking the book

    private func restart(at current: PublicationSpeechSynthesizer.Utterance) async -> Bool {
        paragraph = []
        following = nil
        iterator = publication.content(from: current.locator)?.iterator()
        // the paragraph holding it comes first; a few more in case the place was a little off
        for _ in 0 ..< 6 {
            guard let sentences = await nextElement() else { return false }
            if Self.index(of: current, in: sentences) != nil {
                paragraph = sentences
                return true
            }
        }
        return false
    }

    /// The sentences of the next element that has any.
    private func nextElement() async -> [Sentence]? {
        guard let iterator else { return nil }
        while true {
            guard let content = try? await iterator.next() else { return nil }
            guard let tokenized = try? tokenizer(content) else { continue }
            let sentences = tokenized.flatMap(sentences(of:))
            if !sentences.isEmpty { return sentences }
        }
    }

    /// What read-aloud makes of one element: the same filtering as Readium's synthesizer.
    private func sentences(of element: ContentElement) -> [Sentence] {
        func sentence(text: String, locator: Locator, language: Language?) -> Sentence? {
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Sentence(text: text, locator: locator, language: language == publication.metadata.language ? nil : language)
        }
        switch element {
        case let text as TextContentElement:
            return text.segments.compactMap { sentence(text: $0.text, locator: $0.locator, language: $0.language) }
        case let other as TextualContentElement:
            guard let text = other.text, !text.isEmpty else { return [] }
            return sentence(text: text, locator: other.locator, language: nil).map { [$0] } ?? []
        default:
            return []
        }
    }

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("PTReadAloud lookahead %@", message)
        #endif
    }

    /// Where `utterance` is among `sentences`: the same place in the book (`exact`), or the same words.
    private static func index(of utterance: PublicationSpeechSynthesizer.Utterance, in sentences: [Sentence], exact: Bool) -> Int? {
        exact
            ? sentences.firstIndex { $0.locator == utterance.locator }
            : sentences.firstIndex { $0.text == utterance.text }
    }

    /// The same place in the book, else the same words.
    private static func index(of utterance: PublicationSpeechSynthesizer.Utterance, in sentences: [Sentence]) -> Int? {
        index(of: utterance, in: sentences, exact: true) ?? index(of: utterance, in: sentences, exact: false)
    }
}
