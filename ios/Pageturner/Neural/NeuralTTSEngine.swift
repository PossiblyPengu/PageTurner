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
final class NeuralTTSEngine {
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
        didSet { NeuralPlayer.shared.speed = NeuralPace.stretch(speed: speed, achieved: playingAchieved) }
    }

    /// How much faster than the voice's own pace the sentence playing was made (`NeuralPace`): the player stretches by
    /// the rest of `speed`.
    @MainActor private var playingAchieved: Double = 1

    /// The sentences after the one given, when the book can say what they are.
    @MainActor var upcoming: ((String) async -> [SentenceLookahead.Sentence])?

    /// How much of a sentence's tail its `speak` hands back early, so the next `speak`
    /// has its buffers queued behind it — the sentences follow each other without a gap
    /// of silence. The last sentence of a run gets none: there is nothing to hand to,
    /// and a tail cut by a stop that follows would drop its last beat.
    private static let handoff: TimeInterval = 0.4

    /// Tell Readium which word is being spoken (the highlights that follow words are on).
    @MainActor var reportsWords = true

    /// A page is being looked at. Each sentence's words are timed whenever they are wanted, but only said to Readium
    /// while someone is looking: coming back to the page mid-sentence (the phone unlocked) finds the word the voice
    /// is on at the very next tick, rather than going without a word mark until the next sentence.
    @MainActor var watched = true

    /// Sentences that have been made ahead of being asked for, by voice and text…
    @MainActor private var made: [String: Task<Made, Error>] = [:]
    /// …and the one that was said last, so that picking up after a pause (which starts the sentence
    /// again) doesn't make it twice.
    @MainActor private var recent: (key: String, made: Made)?
    /// Bumped with every sentence that starts playing: a `hurry` set for an earlier one has nothing to say.
    @MainActor private var playing = 0

    /// A sentence ready to be said: its sound, and — when words are followed — when each word starts and where it
    /// is on the page, worked out with the sound, off the main thread.
    private struct Made: Sendable {
        var audio: NeuralSynth.Audio
        var timeline: SpokenWords.Timeline?
        /// How much faster than the voice's own pace it was made.
        var achieved: Double = 1
    }

    /// The pace to make the next sentence at for the speed it will be heard at, and what that pace really gives this
    /// voice. A pace not yet measured for the voice is measured now, in the background (`NeuralSynth.calibrate`), and
    /// meanwhile the sentence is made at the voice's own pace, as before.
    @MainActor
    private func pace(for entry: NeuralVoiceIndex.Entry) -> (pace: Double, achieved: Double) {
        let pace = NeuralPace.made(for: speed)
        guard pace > 1 else { return (1, 1) }
        if let achieved = NeuralSynth.shared.achieved(pace: pace, key: entry.info.key) { return (pace, achieved) }
        NeuralSynth.shared.calibrate(pace: pace, directory: entry.directory, info: entry.info, language: entry.voice.language)
        return (1, 1)
    }

    /// With this much of a sentence still to be heard — or six tenths of it, if that is more: the next one is
    /// likely as long, and takes as long to make — what is being made ahead is no longer made at leisure.
    private static let hurryAt: TimeInterval = 2.5
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
        text: String, voiceOrLanguage: Either<TTSVoice, Language>,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        guard case let .left(chosen) = voiceOrLanguage, let entry = index.entry(forID: chosen.identifier) else {
            return .failure(.other(Failure.notInstalled))
        }
        return await speakText(text, entry: entry, onSpeakRange: onSpeakRange)
    }

    /// Speak `text` in `entry`'s voice — the way a sentence the book resolved to a lesser
    /// voice is read by the neural voice that fits its language instead.
    @MainActor
    func speakText(
        _ text: String,
        entry: NeuralVoiceIndex.Entry,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        let spoken = SpeechText.spoken(text)
        // a segment the voice would say nothing for (a running page number) is dropped
        guard !spoken.isEmpty else { return .success(()) }
        guard !Task.isCancelled else { return .success(()) }
        // the lookahead walks the book — run it beside the making of this sentence, so a
        // cold start (a walk from scratch) doesn't hold the sound up behind it
        async let nextAsked = makeNext(after: text, entry: entry)
        do {
            var ready = try await sentence(text, spoken: spoken, entry: entry)
            // paused, skipped or stopped while it was being made
            if Task.isCancelled { return .success(()) }
            // words turned on since it was made (or it was made before they were wanted): timed now, still off
            // the main thread
            if reportsWords, ready.timeline == nil {
                ready.timeline = await NeuralTTSEngine.timeline(text, spoken: spoken, audio: ready.audio)
                if recent?.key == Self.key(text, entry) { recent?.made = ready }
                if Task.isCancelled { return .success(()) }
            }
            let audio = ready.audio
            let player = NeuralPlayer.shared
            // made at a faster pace or not, it is heard at `speed`: the player stretches by what the voice did not do
            playingAchieved = ready.achieved
            player.speed = NeuralPace.stretch(speed: speed, achieved: ready.achieved)
            // whether the next thing heard is in this voice decides if this sentence's
            // tail may be handed back early to make room for it
            let hasNext = await nextAsked
            if Task.isCancelled { return .success(()) }

            // the word being spoken, as far into the audio as the player says it has got —
            // timed on the cleaned text the voice was given, and put back on the page's own
            let timeline = reportsWords ? ready.timeline : nil
            let words = timeline?.words ?? []
            let seconds = Double(audio.samples.count) / audio.sampleRate
            Self.log("playing \(String(format: "%.2f", seconds)) s, \(words.count) words timed")
            hurryLater(after: seconds)
            var lit = -1
            let cancellation = Cancellation()
            func follow(_ seconds: TimeInterval) -> TimeInterval? {
                guard !cancellation.isSet, let timeline else { return nil }
                let until = timeline.untilNextWord(after: seconds)
                // nobody is watching (the phone is locked, the reader is away): no word to wake for
                guard watched else { return nil }
                guard let next = timeline.index(at: seconds), next != lit else { return until }
                lit = next
                // a word with no counterpart on the page ("to" of a year range, say) keeps the last
                // mark lit rather than the whole sentence flashing over it
                if let range = timeline.written[next] {
                    onSpeakRange(range)
                }
                return until
            }
            // Without words to follow (only the sentence is marked), the sentence is the range: that is
            // what has the page follow the narration, and what shows the voice works
            func sentenceStarted() {
                guard !cancellation.isSet else { return }
                onSpeakRange(text.startIndex ..< text.endIndex)
            }
            let played = await withTaskCancellationHandler {
                await player.enqueue(
                    audio.samples, sampleRate: audio.sampleRate, lead: hasNext ? Self.handoff : 0,
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
    private func sentence(_ text: String, spoken: String, entry: NeuralVoiceIndex.Entry) async throws -> Made {
        let key = Self.key(text, entry)
        if let recent, recent.key == key {
            Self.log("sentence again, from memory")
            return recent.made
        }
        let started = Date()
        if let ahead = made.removeValue(forKey: key) {
            // waited for now: no longer made at leisure
            NeuralSynth.shared.hurry()
            if let ready = try? await ahead.value {
                recent = (key, ready)
                Self.log("sentence made ahead, waited \(Self.ms(since: started)) ms")
                noteWait(Date().timeIntervalSince(started), entry: entry)
                return ready
            }
        }
        let how = pace(for: entry)
        let audio = try await NeuralSynth.shared.generate(
            text: spoken, directory: entry.directory, info: entry.info, sid: entry.sid, pace: how.pace)
        let ready = Made(
            audio: audio, timeline: reportsWords ? await NeuralTTSEngine.timeline(text, spoken: spoken, audio: audio) : nil,
            achieved: how.achieved)
        recent = (key, ready)
        Self.log("sentence made on the spot in \(Self.ms(since: started)) ms")
        return ready
    }

    /// A sentence of `seconds` has started: what is made ahead meanwhile takes its time while there is plenty of
    /// this one left to hear, and is hurried when there is not — it must be there when this one ends.
    @MainActor
    private func hurryLater(after seconds: TimeInterval) {
        playing += 1
        let mine = playing
        let length = seconds / max(NeuralPace.stretch(speed: speed, achieved: playingAchieved), 0.25)
        lastHeardLength = length
        let wait = length - max(Self.hurryAt, length * 0.6)
        guard wait > 0 else {
            NeuralSynth.shared.hurry()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            // still that sentence, and still something being made ahead
            guard let self, self.playing == mine, !self.made.isEmpty else { return }
            NeuralSynth.shared.hurry()
        }
    }

    /// How long the sentence last started takes to hear — the time the one after it had to be made in.
    @MainActor private var lastHeardLength: TimeInterval = 0
    /// When sentences made ahead were still being made at their turn although there had been time to make them.
    @MainActor private var lateTimes: [Date] = []

    /// A sentence made ahead was waited for. After a sentence of three seconds or more (time enough, hurried for the
    /// last two and a half), a wait means the voice cannot keep up on the threads it has: twice in ten minutes and it
    /// is given more (`NeuralSynth.needsMoreThreads`). A short one before it (a heading) proves nothing.
    @MainActor
    private func noteWait(_ waited: TimeInterval, entry: NeuralVoiceIndex.Entry) {
        guard waited > 0.15, lastHeardLength >= 3 else { return }
        let now = Date()
        lateTimes = lateTimes.filter { now.timeIntervalSince($0) < 600 } + [now]
        Log.event("neural", "a sentence made ahead was not ready in time: waited \(Int(waited * 1000)) ms")
        guard lateTimes.count >= 2 else { return }
        lateTimes = []
        NeuralSynth.shared.needsMoreThreads(forKey: entry.info.key)
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

    /// Start making what follows `text`, to have it by the time this one is done — the one
    /// sentence after it, and the one after that, so a slow voice or a fast reader is covered.
    /// Answers whether the next thing heard is in this voice: the hand-off only makes sense
    /// then (a sentence in another language goes to a different voice, and the book's last
    /// sentence has nothing behind it).
    @MainActor
    private func makeNext(after text: String, entry: NeuralVoiceIndex.Entry) async -> Bool {
        guard let upcoming else { return false }
        let started = generation
        let nexts = await upcoming(text)
        guard !nexts.isEmpty else {
            Self.log("no next sentence found")
            return false
        }
        var ours = false
        for (i, next) in nexts.enumerated() {
            // a passage in another language goes to a voice for that language, not to this one
            let fits = next.language.map {
                SpeechVoices.baseLanguage($0.code.bcp47) == SpeechVoices.baseLanguage(entry.voice.language)
            } ?? true
            if i == 0 { ours = fits }
            guard fits, generation == started else { continue }
            Self.log("next sentence found: \(next.text.prefix(24))")
            make(next.text, entry: entry)
        }
        return ours
    }

    /// The best installed neural voice for a language base ("en"), if there is one — what
    /// Automatic routes to when a book's language has a neural voice downloaded.
    func preferredEntry(forBaseLanguage base: String) -> NeuralVoiceIndex.Entry? {
        index.all
            .filter { SpeechVoices.baseLanguage($0.voice.language) == base }
            .max { $0.voice.quality < $1.voice.quality }
    }

    /// Load `identifier`'s model now, so the first sentence asked for doesn't wait for it.
    func warm(_ identifier: String) {
        guard let entry = index.entry(forID: identifier) else { return }
        NeuralSynth.shared.warm(directory: entry.directory, info: entry.info)
    }

    @MainActor
    private func make(_ text: String, entry: NeuralVoiceIndex.Entry) {
        let key = Self.key(text, entry)
        let spoken = SpeechText.spoken(text)
        // nothing a voice would say — don't make anything for it
        guard !spoken.isEmpty else { return }
        guard made[key] == nil else { return }
        // a skip leaves sentences behind that nobody will ask for
        if made.count >= 4 {
            made.values.forEach { $0.cancel() }
            made.removeAll()
        }
        let timed = reportsWords
        let how = pace(for: entry)
        made[key] = Task {
            let audio = try await NeuralSynth.shared.generate(
                text: spoken, directory: entry.directory, info: entry.info, sid: entry.sid, ahead: true, pace: how.pace)
            return Made(
                audio: audio, timeline: timed ? await NeuralTTSEngine.timeline(text, spoken: spoken, audio: audio) : nil,
                achieved: how.achieved)
        }
    }

    private static func key(_ text: String, _ entry: NeuralVoiceIndex.Entry) -> String {
        // by its bytes: two texts Swift calls equal (é written two ways) do not share word ranges
        entry.voice.id + "@" + String(entry.sid) + "\n" + Data(text.utf8).base64EncodedString()
    }

    // MARK: Words

    /// When each word of `spoken` (what the voice was given) starts in `audio`, and where each is in `text` (the
    /// page's): the sound is listened through for its silences and the two texts are walked word by word — work
    /// that held the main thread at the start of every sentence, done here on a thread of its own.
    private static func timeline(_ text: String, spoken: String, audio: NeuralSynth.Audio) async -> SpokenWords.Timeline {
        await Task.detached(priority: .userInitiated) {
            SpokenWords.timeline(spoken: spoken, original: text, samples: audio.samples, sampleRate: audio.sampleRate)
        }.value
    }
}

/// Speaks with whichever engine owns the voice: the neural voices that were downloaded, or the
/// ones iOS ships with. Anything without a chosen neural voice goes to the system.
final class CompositeTTSEngine {
    enum Failure: Error, LocalizedError {
        case silent

        var errorDescription: String? { "The voice said nothing." }
    }

    private let system: SystemTTSEngine
    private let neural: NeuralTTSEngine

    /// When no voice was chosen (Automatic), a sentence a system voice would read goes to the
    /// best installed neural voice for its language instead — Automatic is the best there is
    /// for a book's language, and a downloaded neural voice counts.
    var preferNeural = false

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

    /// Have the voice that will be asked for loaded before the first sentence is: a chosen
    /// neural voice, or the one Automatic will route the book's language to.
    /// Whether a page is being looked at — the device voice reports only each sentence's first word when not.
    @MainActor
    func setWatched(_ watched: Bool) {
        system.watched = watched
    }

    func warmVoice(_ identifier: String?, bookLanguage: String?) {
        if let id = identifier, NeuralVoice.key(fromID: id) != nil {
            neural.warm(id)
            return
        }
        guard preferNeural, let base = bookLanguage.map({ SpeechVoices.baseLanguage($0) }),
              let entry = neural.preferredEntry(forBaseLanguage: base)
        else { return }
        neural.warm(entry.voice.id)
    }

    /// A sentence from its parts — what `SpeechSynthesizer` speaks with.
    @MainActor
    func speak(
        text: String, voiceOrLanguage: Either<TTSVoice, Language>,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        // a task already cancelled starts nothing: a sentence begun now could not be stopped any more
        guard !Task.isCancelled else { return .success(()) }
        let spoken = SpeechText.spoken(text)
        // a segment the voice would say nothing for (a running page number) is dropped
        guard !spoken.isEmpty else { return .success(()) }
        switch voiceOrLanguage {
        case let .left(voice):
            if NeuralVoice.key(fromID: voice.identifier) != nil {
                return await neural.speak(text: text, voiceOrLanguage: voiceOrLanguage, onSpeakRange: onSpeakRange)
            }
        case let .right(language):
            // Automatic — no voice chosen, so the sentence comes with its language alone — and a neural voice is
            // installed for that language: it reads. (This was asked of a chosen system voice, which Automatic
            // never has, so the neural voice it warmed at every start was never heard.)
            if preferNeural, let entry = neural.preferredEntry(forBaseLanguage: SpeechVoices.baseLanguage(language.code.bcp47)) {
                return await neural.speakText(text, entry: entry, onSpeakRange: onSpeakRange)
            }
        }
        // iOS can "finish" a sentence at once without a sound (a voice that is listed but not
        // downloaded, a lost audio session) and the engine reports that as success. Real speech
        // takes far longer than this and says a word on the way; say so, so the failure counter
        // (and the fall-back to the automatic voice) can work.
        let started = Date()
        var spoke = false
        // the original text goes in unchanged — SystemTTSEngine cleans it for the voice and
        // puts each reported range back onto it
        let result = await system.speak(text: text, voiceOrLanguage: voiceOrLanguage) { range in
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
