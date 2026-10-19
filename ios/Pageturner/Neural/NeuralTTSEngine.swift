import AVFoundation
import ReadiumNavigator
import ReadiumShared

extension NeuralVoice {
    /// How Readium sees it: a voice with an identifier it hands back when told to speak with it.
    var ttsVoice: TTSVoice {
        let level: TTSVoice.Quality
        switch quality {
        case .xLow: level = .low
        case .low: level = .medium
        case .medium: level = .high
        case .high: level = .higher
        }
        return TTSVoice(
            identifier: id, language: Language(code: .bcp47(language)), name: displayName,
            gender: .unspecified, quality: level)
    }
}

/// Readium text-to-speech with the neural voices that have been downloaded: sherpa-onnx makes
/// each sentence, `NeuralPlayer` plays it.
///
/// While a sentence plays, the next one is made — the book is asked for it (`upcoming`) — so they
/// follow each other without a wait. A neural voice says nothing about where it is in a sentence,
/// so the word being spoken is worked out from how far the audio has played (`SpokenWords`).
/// The engine is handed the page's own text and cleans it itself right before the voice, putting
/// each word range back onto the original, so the ranges index the same string the locator holds.
final class NeuralTTSEngine: TTSEngine {
    enum Failure: Error, LocalizedError {
        case notInstalled
        case playback

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "That voice isn’t on this iPhone any more."
            case .playback: return "The sound couldn’t be started."
            }
        }
    }

    private let index: NeuralVoiceIndex

    /// How fast to speak (1 is the voice's own pace); changes apply to what is playing too.
    @MainActor var speed: Double = 1 {
        didSet { NeuralPlayer.shared.speed = speed }
    }

    /// The sentence after the one given, when the book can say what it is.
    @MainActor var upcoming: ((String) async -> SentenceLookahead.Sentence?)?

    /// Tell Readium which word is being spoken (the highlights that follow words are on).
    @MainActor var reportsWords = true

    /// Sentences that have been made ahead of being asked for, by voice and text…
    @MainActor private var made: [String: Task<NeuralSynth.Audio, Error>] = [:]
    /// …and the one that was said last, so that picking up after a pause (which starts the sentence
    /// again) doesn't make it twice.
    @MainActor private var recent: (key: String, audio: NeuralSynth.Audio)?
    /// Bumped by `reset`, so a lookahead still in flight can tell it is stale.
    @MainActor private var generation = 0

    init(index: NeuralVoiceIndex) {
        self.index = index
    }

    var availableVoices: [TTSVoice] {
        index.all.map(\.voice.ttsVoice)
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        index.entry(forID: identifier)?.voice.ttsVoice
    }

    @MainActor
    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        let text = utterance.text
        guard case let .left(chosen) = utterance.voiceOrLanguage, let entry = index.entry(forID: chosen.identifier) else {
            return .failure(.other(Failure.notInstalled))
        }
        let spoken = SpeechText.spoken(text)
        // a segment the voice would say nothing for (a running page number) is dropped
        guard !spoken.isEmpty else { return .success(()) }
        guard !Task.isCancelled else { return .success(()) }
        do {
            let audio = try await sentence(text, spoken: spoken, entry: entry)
            // paused, skipped or stopped while it was being made
            if Task.isCancelled { return .success(()) }
            let player = NeuralPlayer.shared
            player.speed = speed
            makeNext(after: text, entry: entry)

            // the word being spoken, as far into the audio as the player says it has got —
            // timed on the cleaned text the voice was given
            let words = reportsWords ? Self.schedule(spoken, audio: audio) : []
            Self.log("playing \(String(format: "%.2f", Double(audio.samples.count) / audio.sampleRate)) s, \(words.count) words timed")
            var lit = -1
            let cancellation = Cancellation()
            func follow(_ seconds: TimeInterval) {
                guard !cancellation.isSet, let next = SpokenWords.index(at: seconds, in: words), next != lit else { return }
                lit = next
                // back onto the page's own text — or the whole sentence when the word
                // has no counterpart there (the "to" of a year range, say)
                onSpeakRange(SpeechText.originalRange(of: words[next].range, spoken: spoken, original: text)
                    ?? text.startIndex ..< text.endIndex)
            }
            // Without words to follow (only the sentence is marked), the sentence is the range: that is
            // what has the page follow the narration, and what shows the voice works
            func sentenceStarted() {
                guard !cancellation.isSet else { return }
                onSpeakRange(text.startIndex ..< text.endIndex)
            }
            let played = await withTaskCancellationHandler {
                await player.enqueue(
                    audio.samples, sampleRate: audio.sampleRate, lead: 0,
                    started: words.isEmpty ? sentenceStarted : nil,
                    progress: words.isEmpty ? nil : follow)
            } onCancel: {
                cancellation.set()
                Task { @MainActor in NeuralPlayer.shared.stop() }
            }
            return played ? .success(()) : .failure(.other(Failure.playback))
        } catch {
            // cancelled while the sentence was being made: a pause or skip, not a failure
            if Task.isCancelled || error is CancellationError { return .success(()) }
            return .failure(.other(error))
        }
    }

    /// Set the moment `speak` is cancelled — by whichever thread cancels it, ahead of the hop to the main
    /// actor that stops the player — so that a word report already on its way is not handed to Readium
    /// after it has paused or stopped (it would put the state back to playing).
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func set() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Forget what was made ahead (read-aloud has stopped).
    @MainActor
    func reset() {
        generation += 1
        made.values.forEach { $0.cancel() }
        made.removeAll()
        recent = nil
    }

    // MARK: Making sentences

    @MainActor
    private func sentence(_ text: String, spoken: String, entry: NeuralVoiceIndex.Entry) async throws -> NeuralSynth.Audio {
        let key = Self.key(text, entry)
        if let recent, recent.key == key {
            Self.log("sentence again, from memory")
            return recent.audio
        }
        let started = Date()
        if let ahead = made.removeValue(forKey: key), let audio = try? await ahead.value {
            recent = (key, audio)
            Self.log("sentence made ahead, waited \(Self.ms(since: started)) ms")
            return audio
        }
        let audio = try await NeuralSynth.shared.generate(text: spoken, directory: entry.directory, info: entry.info)
        recent = (key, audio)
        Self.log("sentence made on the spot in \(Self.ms(since: started)) ms")
        return audio
    }

    /// What the simulator run reads back to see whether sentences really follow without a wait.
    private static func log(_ message: String) {
        #if DEBUG
        NSLog("PTReadAloud neural %@", message)
        #endif
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// Start making the sentence that follows `text`, to have it by the time this one is done.
    @MainActor
    private func makeNext(after text: String, entry: NeuralVoiceIndex.Entry) {
        guard let upcoming else { return }
        let started = generation
        Task { @MainActor [weak self] in
            guard let next = await upcoming(text) else {
                Self.log("no next sentence found")
                return
            }
            Self.log("next sentence found: \(next.text.prefix(24))")
            // a passage in another language goes to a voice for that language, not to this one
            if let other = next.language?.code.bcp47,
               SpeechVoices.baseLanguage(other) != SpeechVoices.baseLanguage(entry.voice.language)
            { return }
            guard let self, self.generation == started else { return }
            self.make(next.text, entry: entry)
        }
    }

    @MainActor
    private func make(_ text: String, entry: NeuralVoiceIndex.Entry) {
        let key = Self.key(text, entry)
        let spoken = SpeechText.spoken(text)
        // nothing a voice would say — don't make anything for it
        guard !spoken.isEmpty else { return }
        guard made[key] == nil else { return }
        // a skip leaves sentences behind that nobody will ask for
        if made.count >= 2 {
            made.values.forEach { $0.cancel() }
            made.removeAll()
        }
        made[key] = Task {
            try await NeuralSynth.shared.generate(text: spoken, directory: entry.directory, info: entry.info)
        }
    }

    private static func key(_ text: String, _ entry: NeuralVoiceIndex.Entry) -> String {
        entry.voice.id + "\n" + text
    }

    // MARK: Words

    /// When each word of `text` is spoken in `audio`.
    private static func schedule(_ text: String, audio: NeuralSynth.Audio) -> [SpokenWords.Word] {
        let speech = SpokenWords.speech(in: audio.samples, sampleRate: audio.sampleRate)
        return SpokenWords.schedule(SpokenWords.words(in: text), speech: speech)
    }
}

/// Speaks with whichever engine owns the voice: the neural voices that were downloaded, or the
/// ones iOS ships with. Anything without a chosen neural voice goes to the system.
final class CompositeTTSEngine: TTSEngine {
    enum Failure: Error, LocalizedError {
        case silent

        var errorDescription: String? { "The voice said nothing." }
    }

    private let system: SystemTTSEngine
    private let neural: NeuralTTSEngine

    init(system: SystemTTSEngine, neural: NeuralTTSEngine) {
        self.system = system
        self.neural = neural
    }

    var availableVoices: [TTSVoice] {
        system.availableVoices + neural.availableVoices
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        NeuralVoice.key(fromID: identifier) != nil
            ? neural.voiceWithIdentifier(identifier)
            : system.voiceWithIdentifier(identifier)
    }

    @MainActor
    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        // a play task parked between sentences outlives the cancel pause/stop sent it — without
        // this it would still start the engine below: a sentence nobody can stop any more
        guard !Task.isCancelled else { return .success(()) }
        let spoken = SpeechText.spoken(utterance.text)
        // a segment the voice would say nothing for (a running page number) is dropped
        guard !spoken.isEmpty else { return .success(()) }
        if case let .left(voice) = utterance.voiceOrLanguage, NeuralVoice.key(fromID: voice.identifier) != nil {
            return await neural.speak(utterance, onSpeakRange: onSpeakRange)
        }
        // iOS can "finish" a sentence at once without a sound (a voice that is listed but not
        // downloaded, a lost audio session) and the engine reports that as success. Real speech
        // takes far longer than this and says a word on the way; say so, so the failure counter
        // (and the fall-back to the automatic voice) can work.
        let started = Date()
        var spoke = false
        // the original text goes in unchanged — SystemTTSEngine cleans it for the voice and
        // puts each reported range back onto it
        let result = await system.speak(utterance) { range in
            spoke = true
            onSpeakRange(range)
        }
        if case .success = result, !spoke, !Task.isCancelled,
           spoken.count >= 12,
           Date().timeIntervalSince(started) < 0.25
        {
            return .failure(.other(Failure.silent))
        }
        return result
    }
}
