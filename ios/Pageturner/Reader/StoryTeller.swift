import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (iOS 26 on an iPhone with Apple Intelligence), for "The Story So Far" and "Who's This?".
/// It runs on the phone and only when asked; nothing is sent anywhere. Where it can't be asked the two are not
/// offered at all.
enum StoryAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    enum Failure: Error, Equatable {
        case unavailable
        /// More text than the model can take in one request.
        case tooLong
        /// The model would not answer about this text.
        case declined
        case other(String)
    }

    /// One answer to `prompt`, the model told `instructions` first — a session of its own each time, so one
    /// request's text never crowds the next one's out of the model's window.
    static func ask(_ prompt: String, instructions: String, length: Int = 220) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: length)
            do {
                let response = try await session.respond(to: prompt, options: options)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize: throw Failure.tooLong
                case .guardrailViolation: throw Failure.declined
                default: throw Failure.other(error.localizedDescription)
                }
            }
        }
        #endif
        throw Failure.unavailable
    }
}

/// A chapter of the book up to the reader's place: the current one cut there.
struct StoryChapter: Sendable {
    /// The chapter's file in the book — what its recap is kept under.
    let href: String
    let title: String
    let text: String
    /// The chapter the reader is in, cut at their place: its recap is made each time, not kept.
    let partial: Bool
}

/// "The Story So Far": a few sentences on each chapter read — the latest made now, the earlier ones kept from
/// before (`Recaps/<book>.json`), all of them on asking — and the story in one paragraph from those.
@MainActor
final class StoryTeller: ObservableObject {
    struct Recap: Identifiable, Equatable {
        let id: String
        let chapter: String
        let summary: String
        /// The model would not summarize it: shown as such, never kept.
        var declined = false
        var partial = false
    }

    enum Phase: Equatable {
        case idle
        case reading(done: Int, of: Int)
        case telling
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recaps: [Recap] = []
    @Published private(set) var story: String?
    /// Chapters read whose recap was neither kept nor made this time (`tell(fromStart: false)`).
    @Published private(set) var skipped = 0

    private let bookID: UUID
    private let bookTitle: String
    private var task: Task<Void, Never>?

    /// How many of the latest chapters are recapped by default; the rest only when kept from before, or on asking.
    static let recent = 3

    init(bookID: UUID, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
    }

    var isWorking: Bool {
        switch phase {
        case .reading, .telling: return true
        default: return false
        }
    }

    func tell(_ chapters: [StoryChapter], fromStart: Bool) {
        task?.cancel()
        story = nil
        recaps = []
        skipped = 0
        guard !chapters.isEmpty else {
            phase = .failed("There’s nothing read in this book yet to tell.")
            return
        }
        let book = bookTitle
        let id = bookID
        task = Task { [weak self] in
            var cache = Self.loadCache(id)
            var made: [Recap] = []
            let fresh = fromStart ? chapters.count : min(Self.recent, chapters.count)
            let firstFresh = chapters.count - fresh
            var skipped = 0
            for (i, chapter) in chapters.enumerated() {
                guard !Task.isCancelled, let self else { return }
                self.phase = .reading(done: i, of: chapters.count)
                if !chapter.partial, let kept = cache.recaps[chapter.href] {
                    made.append(Recap(id: chapter.href, chapter: chapter.title, summary: kept))
                    self.recaps = made
                    continue
                }
                guard i >= firstFresh else {
                    skipped += 1
                    continue
                }
                do {
                    let summary = try await Self.summarize(chapter, book: book)
                    guard !Task.isCancelled else { return }
                    made.append(Recap(id: chapter.href, chapter: chapter.title, summary: summary, partial: chapter.partial))
                    if !chapter.partial {
                        cache.recaps[chapter.href] = summary
                        Self.saveCache(cache, id)
                    }
                } catch StoryAI.Failure.declined {
                    made.append(Recap(id: chapter.href, chapter: chapter.title,
                                      summary: "Apple’s model wouldn’t summarize this part.", declined: true, partial: chapter.partial))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.phase = .failed(Self.describe(error))
                    self.recaps = made
                    return
                }
                self.recaps = made
            }
            guard !Task.isCancelled, let self else { return }
            self.skipped = skipped
            self.phase = .telling
            let usable = made.filter { !$0.declined }.map { (chapter: $0.chapter, summary: $0.summary) }
            if !usable.isEmpty {
                self.story = try? await StoryAI.ask(
                    StoryRecap.storyPrompt(book: book, recaps: usable),
                    instructions: StoryRecap.recapInstructions, length: 320)
            }
            guard !Task.isCancelled else { return }
            self.phase = .done
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { phase = .idle }
    }

    // MARK: -

    /// A chapter in a few sentences: in one request when it fits, else piece by piece and the pieces joined.
    private static func summarize(_ chapter: StoryChapter, book: String) async throws -> String {
        func one(_ text: String) async throws -> String {
            do {
                return try await StoryAI.ask(
                    StoryRecap.chapterPrompt(book: book, chapter: chapter.title, text: text, partial: chapter.partial),
                    instructions: StoryRecap.recapInstructions)
            } catch StoryAI.Failure.tooLong {
                // more tokens to the letter than English has (another language, odd text): in halves
                let halves = StoryRecap.pieces(of: text, limit: max(text.count / 2, 500))
                var parts: [String] = []
                for half in halves.prefix(4) {
                    parts.append(try await StoryAI.ask(
                        StoryRecap.chapterPrompt(book: book, chapter: chapter.title, text: half, partial: chapter.partial),
                        instructions: StoryRecap.recapInstructions))
                }
                return try await StoryAI.ask(StoryRecap.joinPrompt(chapter: chapter.title, parts: parts),
                                             instructions: StoryRecap.recapInstructions)
            }
        }
        let pieces = StoryRecap.pieces(of: chapter.text)
        guard pieces.count > 1 else { return try await one(chapter.text) }
        var parts: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            parts.append(try await one(piece))
        }
        return try await StoryAI.ask(StoryRecap.joinPrompt(chapter: chapter.title, parts: parts),
                                     instructions: StoryRecap.recapInstructions)
    }

    static func describe(_ error: Error) -> String {
        switch error as? StoryAI.Failure {
        case .unavailable: return "Apple Intelligence isn’t available on this iPhone right now."
        case .tooLong: return "That was more than the model can read at once."
        case .declined: return "Apple’s model wouldn’t answer about this part of the book."
        case .other(let message): return message
        case nil: return error.localizedDescription
        }
    }

    // MARK: Kept recaps

    private struct Cache: Codable {
        var version = StoryRecap.version
        var recaps: [String: String] = [:]
    }

    private static func cacheURL(_ id: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Recaps", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private static func loadCache(_ id: UUID) -> Cache {
        guard let data = try? Data(contentsOf: cacheURL(id)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == StoryRecap.version
        else { return Cache() }
        return cache
    }

    private static func saveCache(_ cache: Cache, _ id: UUID) {
        let url = cacheURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
    }
}

/// "Who's This?": what the passages read so far say about someone, from the model.
@MainActor
final class WhoTeller: ObservableObject {
    enum Phase: Equatable {
        case looking
        case answered(String, mentions: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .looking
    private var task: Task<Void, Never>?

    func ask(about name: String, book: String, chapters: [StoryChapter]) {
        task?.cancel()
        phase = .looking
        task = Task { [weak self] in
            let read = chapters.map { (title: $0.title, text: $0.text) }
            let passages = await Task.detached { StoryRecap.mentions(of: name, in: read, limit: 20) }.value
            guard !Task.isCancelled, let self else { return }
            guard !passages.isEmpty else {
                self.phase = .failed("“\(name)” hasn’t come up in what you’ve read so far.")
                return
            }
            do {
                let answer = try await StoryAI.ask(
                    StoryRecap.whoPrompt(name: name, book: book, passages: passages),
                    instructions: StoryRecap.whoInstructions, length: 200)
                guard !Task.isCancelled else { return }
                self.phase = .answered(answer, mentions: passages.count)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(StoryTeller.describe(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
