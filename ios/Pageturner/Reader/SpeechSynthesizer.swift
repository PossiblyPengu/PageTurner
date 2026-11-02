import Foundation
import ReadiumNavigator
import ReadiumShared

/// Told what the voice is doing — the same calls Readium's `PublicationSpeechSynthesizerDelegate` makes.
@MainActor
protocol SpeechSynthesizerDelegate: AnyObject {
    func publicationSpeechSynthesizer(_ synthesizer: SpeechSynthesizer, stateDidChange state: SpeechSynthesizer.State)
    func publicationSpeechSynthesizer(
        _ synthesizer: SpeechSynthesizer, utterance: SpeechSynthesizer.Utterance,
        didFailWithError error: SpeechSynthesizer.Error)
}

/// Reads a publication aloud a sentence at a time: Readium's `PublicationSpeechSynthesizer`, kept to the main
/// thread.
///
/// Readium's runs its play loop on a background executor and changes its `state` there, while the word reports
/// change it on the main thread and read-aloud reads it there for every word — two threads writing and reading the
/// same enum with nothing between them. Almost always they miss each other; over hours of listening, once they
/// don't, and the app dies copying a half-written state (the crash after long sessions). This is the same loop —
/// iterate the book's content, split it into sentences with the reading tokenizer, speak each with the engine —
/// with every step on the main actor, and the state handed to the delegate in order, as it was set.
///
/// A task cancelled by a pause, a skip or a stop sets nothing after it (Readium's could still report `.playing`
/// for a sentence after a pause — the "ghost" read-aloud had to squash).
@MainActor
final class SpeechSynthesizer {
    typealias Configuration = PublicationSpeechSynthesizer.Configuration
    typealias TokenizerFactory = (_ defaultLanguage: Language?) -> ContentTokenizer

    /// A sentence of the book to be said.
    struct Utterance: Equatable {
        let text: String
        let locator: Locator
        /// Only when it differs from the book's own language.
        let language: Language?
    }

    enum State: Equatable {
        case stopped
        case paused(Utterance)
        /// `range` follows the word being said.
        case playing(Utterance, range: Locator?)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }
    }

    enum Error: Swift.Error {
        case engine(TTSError)
    }

    static func canSpeak(publication: Publication) -> Bool {
        publication.content() != nil
    }

    private(set) var state: State = .stopped {
        didSet {
            if oldValue.isPlaying != state.isPlaying {
                audioSession.user(audioSessionUser, didChangePlaying: state.isPlaying)
            }
            // handed on after this call returns (the delegate may pause or skip in answer), in the order set
            let value = state
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.publicationSpeechSynthesizer(self, stateDidChange: value)
            }
        }
    }

    /// Takes effect from the next sentence.
    var config: Configuration
    weak var delegate: SpeechSynthesizerDelegate?

    private let publication: Publication
    private let engine: CompositeTTSEngine
    private let tokenizerFactory: TokenizerFactory
    // read by `deinit`, which runs off the main actor; neither changes after init
    nonisolated(unsafe) private let audioSession: AudioSessionManaging
    nonisolated(unsafe) private let audioSessionUser = SessionUser()
    private var currentTask: Task<Void, Never>?
    private var iterator: ContentIterator? {
        didSet {
            utterances = Cursor()
            iteration += 1
            loading = nil
        }
    }
    /// Which iterator `utterances` and `loading` belong to: counted up each time it is replaced.
    private var iteration = 0
    /// The sentences of the content element being read.
    private var utterances = Cursor()
    /// The one call to the content iterator under way. The iterator's `next` runs off the main actor and is not
    /// safe to step from two places at once, and a pause or a skip cancels the task that asked while the call
    /// goes on: whoever asks next waits for that call and takes what it found, rather than stepping again
    /// (which raced the iterator, and lost the paragraph it had found).
    private var loading: Task<Bool, Never>?
    /// A `start` still finding its first sentence: Play pressed meanwhile carries on with that, not with the
    /// sentence paused before it.
    private var starting = false
    private var lastUsedVoice: TTSVoice?

    init(publication: Publication, config: Configuration, engine: CompositeTTSEngine,
         tokenizerFactory: @escaping TokenizerFactory)
    {
        self.publication = publication
        self.config = config
        self.engine = engine
        self.tokenizerFactory = tokenizerFactory
        audioSession = AudioSession.shared
    }

    deinit {
        audioSession.end(for: audioSessionUser)
    }

    var availableVoices: [TTSVoice] { engine.availableVoices }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        if let voice = lastUsedVoice, voice.identifier == identifier { return voice }
        let voice = engine.voiceWithIdentifier(identifier)
        lastUsedVoice = voice
        return voice
    }

    // MARK: Controls

    /// (Re)starts from `locator`, or the beginning of the book.
    func start(from locator: Locator? = nil) {
        audioSession.start(with: audioSessionUser, isPlaying: false)
        currentTask?.cancel()
        iterator = publication.content(from: locator)?.iterator()
        starting = true
        currentTask = Task { await run(.forward) }
    }

    func stop() {
        currentTask?.cancel()
        starting = false
        state = .stopped
        iterator = nil
    }

    func pause() {
        currentTask?.cancel()
        if case let .playing(utterance, range: _) = state {
            state = .paused(utterance)
        }
    }

    func resume() {
        if starting {
            currentTask?.cancel()
            currentTask = Task { await run(.forward) }
        } else if case let .paused(utterance) = state {
            currentTask?.cancel()
            currentTask = Task { await run(.forward, from: utterance) }
        }
    }

    func pauseOrResume() {
        switch state {
        case .stopped: return
        case .playing: pause()
        case .paused: resume()
        }
    }

    func previous() {
        // nothing started (or stopped): a skip has no book to move in, and must not report `.stopped`
        guard iterator != nil else { return }
        // at the book's first sentence there is none before it: that one is said again, not the end
        let current: Utterance?
        switch state {
        case let .playing(utterance, range: _), let .paused(utterance): current = utterance
        case .stopped: current = nil
        }
        currentTask?.cancel()
        currentTask = Task { await run(.backward, orElse: current) }
    }

    func next() {
        guard iterator != nil else { return }
        currentTask?.cancel()
        currentTask = Task { await run(.forward) }
    }

    // MARK: The play loop

    private enum Direction { case forward, backward }

    /// Says sentence after sentence — `first`, if given, then the next one `direction` finds, then on forward —
    /// until the book ends, a sentence fails, or the task is cancelled. One loop, not a chain of calls: each
    /// sentence used to await the next one's call, and a night's listening held every one of them until a pause.
    private func run(_ direction: Direction, from first: Utterance? = nil, orElse fallback: Utterance? = nil) async {
        var direction = direction
        var pending = first
        var fallback = fallback
        while true {
            let utterance: Utterance
            if let given = pending {
                utterance = given
                pending = nil
            } else {
                let found = await nextUtterance(direction)
                // a newer pause, skip or stop owns the state now
                guard !Task.isCancelled else { return }
                guard let found = found ?? fallback else {
                    starting = false
                    state = .stopped
                    return
                }
                fallback = nil
                utterance = found
            }
            guard !Task.isCancelled else { return }
            direction = .forward
            starting = false
            state = .playing(utterance, range: nil)
            let result = await engine.speak(text: utterance.text, voiceOrLanguage: voiceOrLanguage(for: utterance)) { [weak self] range in
                // a word of a sentence that is no longer the one being said (its report was on its way) is dropped
                guard let self, case let .playing(current, range: _) = self.state, current == utterance else { return }
                self.state = .playing(utterance, range: utterance.locator.copy(text: { text in
                    guard let highlight = text.highlight,
                          highlight.startIndex <= range.lowerBound, highlight.endIndex >= range.upperBound
                    else { return }
                    text = text[range]
                }))
            }
            guard !Task.isCancelled else { return }
            if case let .failure(error) = result {
                // told first: the delegate mostly carries on (a skip, a retry with another voice) or stops, and a
                // pause shown for the moment before that only flickered the controls
                let task = currentTask
                delegate?.publicationSpeechSynthesizer(self, utterance: utterance, didFailWithError: .engine(error))
                if currentTask == task, case .playing = state { state = .paused(utterance) }
                return
            }
        }
    }

    /// The chosen voice when it speaks the sentence's language, else the language for the engine to pick a voice.
    private func voiceOrLanguage(for utterance: Utterance) -> Either<TTSVoice, Language> {
        if let id = config.voiceIdentifier, let voice = voiceWithIdentifier(id),
           utterance.language == nil || utterance.language?.removingRegion() == voice.language.removingRegion()
        {
            return .left(voice)
        }
        return .right(utterance.language ?? config.defaultLanguage ?? publication.metadata.language ?? Language.current)
    }

    /// The next sentence that way, or nil at the book's end, on a read error, or when the task was cancelled —
    /// in which case the cursor is left where it was, so the next ask gets the sentence this one would have.
    private func nextUtterance(_ direction: Direction) async -> Utterance? {
        while true {
            if let utterance = utterances.step(forward: direction == .forward) { return utterance }
            guard await loadNextUtterances(direction), !Task.isCancelled else { return nil }
        }
    }

    /// Moves `utterances` to the next content element that has sentences (going back, the one before), the cursor
    /// before its first (going back, after its last). False at the end of the book, or on a read error.
    private func loadNextUtterances(_ direction: Direction) async -> Bool {
        // a call a pause or a skip left running is stepping the iterator: what it finds is what comes next
        if let loading { return await loading.value }
        guard let iterator else { return false }
        let iteration = self.iteration
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let found = await self.load(direction, from: iterator, iteration: iteration)
            // cleared before anyone waiting on it runs, so they never wait on a finished call again
            if self.iteration == iteration { self.loading = nil }
            return found
        }
        loading = task
        return await task.value
    }

    private func load(_ direction: Direction, from iterator: ContentIterator, iteration: Int) async -> Bool {
        do {
            var found: [Utterance] = []
            while found.isEmpty {
                let element: ContentElement?
                switch direction {
                case .forward: element = try await iterator.next()
                case .backward: element = try await iterator.previous()
                }
                guard let element else { return false }
                found = try tokenizerFactory(config.defaultLanguage ?? publication.metadata.language)(element)
                    .flatMap { utterances(for: $0) }
            }
            // the iterator was replaced (a new start, a stop) while this one read: its sentences are not wanted
            guard self.iteration == iteration else { return false }
            utterances = Cursor(list: found, startIndex: direction == .forward ? 0 : found.count - 1)
            return true
        } catch {
            Log.error("readaloud", "reading the book's text failed: \(error)")
            return false
        }
    }

    private func utterances(for element: ContentElement) -> [Utterance] {
        func utterance(_ text: String, _ locator: Locator, _ language: Language?) -> Utterance? {
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            // the book's own language is left out, so the configuration's default can stand for it
            let own = language == publication.metadata.language ? nil : language
            return Utterance(text: text, locator: locator, language: own)
        }
        if let element = element as? TextContentElement {
            return element.segments.compactMap { utterance($0.text, $0.locator, $0.language) }
        }
        if let element = element as? TextualContentElement, let text = element.text, !text.isEmpty {
            return [utterance(text, element.locator, nil)].compactMap { $0 }
        }
        return []
    }

    // MARK: Pieces

    /// A list with a cursor that starts before the first step: the first `step` lands on `startIndex`.
    private struct Cursor {
        private let list: [Utterance]
        private let startIndex: Int
        private var index: Int?

        init(list: [Utterance] = [], startIndex: Int = 0) {
            self.list = list
            self.startIndex = startIndex
        }

        mutating func step(forward: Bool) -> Utterance? {
            let target = index.map { forward ? $0 + 1 : $0 - 1 } ?? startIndex
            guard list.indices.contains(target) else { return nil }
            index = target
            return list[target]
        }
    }

    private final class SessionUser: AudioSessionUser {
        let audioConfiguration = AudioSession.Configuration(
            category: .playback, mode: .spokenAudio, routeSharingPolicy: .longFormAudio)
        func play() {}
    }
}
