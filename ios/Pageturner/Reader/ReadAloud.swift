import AVFoundation
import Combine
import MediaPlayer
import ReadiumNavigator
import ReadiumShared
import UIKit

/// Tunes every utterance Readium's AVTTSEngine creates (its own configuration has no
/// rate setting, and it asks iOS for "a voice for this language", which answers with the
/// compact default even when a better one is installed).
final class SpeechTuning: AVTTSEngineDelegate {
    /// 1 = the voice's normal pace.
    var multiplier: Double = 1.0
    /// The voice the reader picked, if any: the one thing never to second-guess.
    var chosenVoiceID: String?
    private lazy var installed = SystemVoices.installed()

    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        utterance.rate = SpeechRateMap.avRate(forMultiplier: multiplier)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        // Not the chosen voice (no choice, or a voice for another language than this
        // passage): "Automatic" — the best Enhanced/Premium voice for its language.
        guard let voice = utterance.voice, voice.identifier != chosenVoiceID,
              let better = SpeechVoices.upgrade(
                  for: voice.language, among: installed, preferred: Locale.preferredLanguages),
              better.id != voice.identifier,
              let upgraded = AVSpeechSynthesisVoice(identifier: better.id)
        else { return }
        utterance.voice = upgraded
    }
}

/// Read-aloud on Readium's PublicationSpeechSynthesizer and the system voices.
/// Speech runs through AVSpeechSynthesizer on a .playback audio session, so it
/// keeps going with the screen locked and shows on the lock screen.
@MainActor
final class ReadAloud: NSObject, ObservableObject {
    @Published private(set) var isActive = false   // controls shown
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Double
    /// Seconds left on the sleep timer, nil when unset.
    @Published private(set) var sleepRemaining: TimeInterval?
    /// Estimated seconds of narration left in the book, once enough of it has
    /// played to judge; nil before that.
    @Published private(set) var estimatedRemaining: TimeInterval?

    private let publication: Publication
    private weak var navigator: VisualNavigator?
    private let synthesizer: PublicationSpeechSynthesizer
    private let tuning: SpeechTuning
    private let neural: NeuralTTSEngine
    private let startup = AudioStartup()
    /// Something else owns the stage (a voice sample, the audiobook, the voice sheet):
    /// narration stays paused until the reader asks for it. A play task parked between
    /// sentences outlives Readium's cancel and reports .playing once more — this flag
    /// squashes that ghost instead of letting the voice come back over the new owner.
    private var heldForFocus = false
    /// The library record's values — the publication's own metadata can name
    /// a different edition than the title the user edited.
    private let displayTitle: String
    private let displayAuthor: String

    /// What is being said now: the sentence, and the word in it.
    private struct Spoken: Equatable {
        var sentence: Locator?
        var word: Locator?

        /// The "word" is the whole of a sentence of several: the voice (or a neural voice told to follow
        /// only the sentence) named no word. That is no word to mark, and no line.
        var wordIsTheSentence: Bool {
            guard let said = word?.text.highlight, said == sentence?.text.highlight else { return false }
            return SpokenWords.words(in: said).count > 1
        }
    }

    @Published private var spoken = Spoken()
    /// The sentence a voice has named a word of, and the wait for it to: a voice that never does
    /// (some don't) would leave the first word lit for the whole sentence.
    private var namedAWordIn: Locator?
    private var wordTimeout: Task<Void, Never>?
    /// What is lit while it reads.
    @Published private(set) var highlights: ReadAloudHighlights
    /// Where the page is taken to follow the narration: the word being said in a paged book, the
    /// sentence in a scrolling one (a scrolling page that put each word at the top would never be still).
    private let followTarget = PassthroughSubject<Locator, Never>()
    /// Where the follow is taking the page next; the newest send wins — a
    /// swallowed jump waits here for the retry, not back in the subject where
    /// removeDuplicates would drop it.
    private var pendingFollow: Locator?
    private var isTurning = false
    private var consecutiveFailures = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?
    /// The navigator that takes decorations — kept so a Low Power Mode change
    /// can repaint without waiting for the next spoken thing.
    private var decorable: DecorableNavigator?
    private var lowPowerObserver: NSObjectProtocol?
    /// A call or Siri taking the session makes iOS cancel the utterance — and Readium's
    /// AVTTSEngine reports a cancel as finished, so without this the synthesizer walks
    /// silently through sentences nobody hears, and three of those read as failures that
    /// drop the chosen voice. The session's interruption notice is the real signal.
    private var interruptionObserver: NSObjectProtocol?
    /// When an interruption that paused mid-sentence narration began: `.ended` resumes
    /// only a pause this made while speaking, and only if it wasn't an age ago.
    private var interruptedWhilePlaying: Date?
    /// An engine failure reports `.paused` a moment before `didFailWithError` —
    /// the retry then plays on, so a "pause" shorter than a beat is never
    /// shown. A real pause outlives this and surfaces normally.
    private var pauseFlash: Task<Void, Never>?
    /// Seconds actually spoken this session (pauses don't count) — the lock
    /// screen's clock is estimated from how fast the narration moves.
    private var playedSeconds: TimeInterval = 0
    private var lastTickAt: Date?
    /// Where narration began, for the estimate's progress baseline.
    private var startProgression: Double?
    private var currentProgression: Double = 0
    /// Estimated seconds the whole book takes to read aloud, once enough of it
    /// has played to judge; nil before that.
    private var estimatedDuration: TimeInterval?
    private var artworkItem: MPMediaItemArtwork?
    /// A failed cover fetch doesn't retry every sentence — once is enough.
    private var artworkTried = false

    /// Surfaces problems the caller should show (e.g. utterances keep failing).
    var onError: ((String) -> Void)?
    /// Called when the session ends, however it ended (the reader, the sleep timer, repeated failures).
    var onStopped: (() -> Void)?
    /// Called when a chosen voice proved unusable and was dropped for the
    /// automatic one — the caller should clear its persisted voice setting.
    var onVoiceFallback: (() -> Void)?

    static func canSpeak(_ publication: Publication) -> Bool {
        PublicationSpeechSynthesizer.canSpeak(publication: publication)
    }

    init?(publication: Publication, navigator: VisualNavigator, settings: ReaderSettings,
          displayTitle: String, displayAuthor: String)
    {
        let tuning = SpeechTuning()
        tuning.multiplier = settings.speechRate
        tuning.chosenVoiceID = settings.voiceIdentifier
        // the voices iOS ships with, and the neural ones that have been downloaded
        let neural = NeuralTTSEngine(index: NeuralVoiceStore.shared.index)
        neural.speed = settings.speechRate
        // Low Power Mode drops the per-word work entirely: no word schedule,
        // no 30Hz playhead report, no mark repainted for every word
        neural.reportsWords = settings.highlights.needsWords && !LowPower.on
        guard let synthesizer = PublicationSpeechSynthesizer(
            publication: publication,
            config: .init(voiceIdentifier: settings.voiceIdentifier),
            engineFactory: { CompositeTTSEngine(system: AVTTSEngine(delegate: tuning), neural: neural) },
            tokenizerFactory: makeReadingTokenizer
        ) else { return nil }

        self.publication = publication
        self.navigator = navigator
        self.synthesizer = synthesizer
        self.tuning = tuning
        self.neural = neural
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        rate = settings.speechRate
        highlights = settings.highlights
        super.init()
        synthesizer.delegate = self
        // the next sentence is made while this one is said: ask the book what it is
        let lookahead = SentenceLookahead(publication: publication)
        neural.upcoming = { [weak self] text in
            guard let self, case let .playing(utterance, range: _) = self.synthesizer.state, utterance.text == text else { return nil }
            return await lookahead.sentence(after: utterance)
        }

        // light the sentence, the line and the word being spoken, as chosen
        if let decorable = navigator as? DecorableNavigator {
            self.decorable = decorable
            Publishers.CombineLatest($spoken, $highlights)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .sink { [weak self] spoken, highlights in
                    self?.paint(spoken, as: highlights, on: decorable)
                }
                .store(in: &subscriptions)
            // iOS toggling Low Power Mode mid-book adds or drops the word marks
            // on the next repaint rather than the next open
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: LowPower.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.neural.reportsWords = self.highlights.needsWords && !LowPower.on
                    self.paint(self.spoken, as: self.highlights, on: decorable)
                }
            }
        }

        // a call or an alarm takes the audio session: iOS cancels the utterance, which
        // AVTTSEngine passes on as finished — hold a real pause instead, then resume
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    guard self.isActive else { return }
                    let wasPlaying = self.isPlaying
                    self.pauseForOtherAudio()
                    self.interruptedWhilePlaying = wasPlaying ? Date() : nil
                    Log.event("readaloud", "interrupted" + (wasPlaying ? " while speaking" : ""))
                case .ended:
                    // a call, Siri or an alarm that is over: carry on, unless it has been so
                    // long that the reader has surely moved on (or they paused meanwhile)
                    defer { self.interruptedWhilePlaying = nil }
                    guard self.isActive, options.contains(.shouldResume),
                          let at = self.interruptedWhilePlaying,
                          Date().timeIntervalSince(at) < 300 else { return }
                    Log.event("readaloud", "interruption over — resuming")
                    self.playPause()
                @unknown default: break
                }
            }
        }

        // follow the narration, turning pages mid-sentence when needed
        followTarget
            .removeDuplicates()
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] locator in
                guard let self else { return }
                self.pendingFollow = locator
                self.follow()
            }
            .store(in: &subscriptions)
    }

    // MARK: - Following

    /// Take the page to `pendingFollow`, newest target first. The navigator
    /// refuses a `go` while it is mid-jump or mid-turn — exactly when narration
    /// crosses a chapter — and a refused jump is what leaves the page a chapter
    /// behind the marks, so a no just waits a moment and goes again. A fresh
    /// target arriving meanwhile replaces the stale one rather than queueing.
    private func follow() {
        guard !isTurning, let navigator else { return }
        isTurning = true
        Task { @MainActor in
            var attempts = 0
            while let locator = pendingFollow, attempts < 15 {
                pendingFollow = nil
                attempts += 1
                let epub = navigator as? EPUBNavigatorViewController
                let scrolledFrom = scrolls ? await epub?.scrollTop() : nil
                if await navigator.go(to: locator, options: NavigatorGoOptions(animated: true)) {
                    if let epub, let scrolledFrom {
                        await centerSpokenLine(on: epub, pageWasAt: scrolledFrom)
                    }
                    attempts = 0
                } else {
                    pendingFollow = pendingFollow ?? locator
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            isTurning = false
        }
    }

    // MARK: - Controls

    var isFollowingNarration: Bool { isTurning }

    private func registerAudio() {
        AudioFocus.shared.register(
            "readaloud", pause: { [weak self] in self?.pauseForOtherAudio() },
            remote: RemoteControls.Handlers(
                play: { [weak self] in self?.playPauseIfPaused() },
                pause: { [weak self] in self?.pauseForOtherAudio() },
                toggle: { [weak self] in self?.playPause() },
                next: { [weak self] in self?.next() },
                previous: { [weak self] in self?.previous() },
                refresh: { [weak self] in self?.publishNowPlaying() }))
    }

    private func playPauseIfPaused() {
        if case .playing = synthesizer.state { return }
        playPause()
    }

    /// Another sound claimed the stage (or the voice sheet opened): hold the narration
    /// where it is. Pausing unconditionally also kills a play task parked between
    /// sentences — exactly the "between the lines" moment a cancelled one would speak through.
    private func pauseForOtherAudio() {
        startup.cancel()
        heldForFocus = true
        synthesizer.pause()
    }

    /// Start from the first sentence on screen.
    func start() {
        heldForFocus = false
        registerAudio()
        AudioFocus.shared.claim("readaloud")
        isActive = true
        startup.start(locate: { [weak self] in
            await self?.navigator?.firstVisibleElementLocator() ?? self?.navigator?.currentLocation
        }, play: { [weak self] start in
            self?.synthesizer.start(from: start)
        })
        publishNowPlaying()
    }

    func playPause() {
        heldForFocus = false
        if case .stopped = synthesizer.state { start(); return }
        // about to speak again (it was paused): take focus from anything else
        if case .playing = synthesizer.state {} else { AudioFocus.shared.claim("readaloud") }
        synthesizer.pauseOrResume()
    }

    /// Skipping while paused speaks — take the stage back first.
    func next() {
        heldForFocus = false
        AudioFocus.shared.claim("readaloud")
        synthesizer.next()
    }

    func previous() {
        heldForFocus = false
        AudioFocus.shared.claim("readaloud")
        synthesizer.previous()
    }

    deinit {
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func stop() {
        startup.cancel()
        // keep holding: a task parked between sentences can still report .playing
        // after this — it must not bring a stopped session's controls back to life
        heldForFocus = true
        synthesizer.stop()
        // the synthesizer tells us it has stopped in a moment — by then this may be gone, and the
        // marks would stay on the page
        wordTimeout?.cancel()
        namedAWordIn = nil
        spoken = Spoken()
        pendingFollow = nil
        neural.reset()
        NeuralSynth.shared.unload()   // the model's memory back
        AudioFocus.shared.unregister("readaloud")
        isActive = false
        setSleepTimer(minutes: nil)
        onStopped?()
    }

    // MARK: - Sleep timer

    /// Stop read-aloud after the given number of minutes; nil cancels. One bell
    /// rung once at the deadline — the label refreshes on each spoken sentence
    /// (`noteProgression`), so no poll is needed just to count down.
    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes, minutes > 0 else {
            sleepDeadline = nil
            sleepRemaining = nil
            return
        }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepDeadline = deadline
        sleepRemaining = deadline.timeIntervalSinceNow
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let deadline = self.sleepDeadline, Date() >= deadline else { return }
                self.stop()   // stop() also clears the timer
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    /// Takes effect from the next sentence.
    func setRate(_ value: Double) {
        rate = value
        tuning.multiplier = value
        neural.speed = value
    }

    /// What is lit changes at once, even in the middle of a sentence.
    func setHighlights(_ value: ReadAloudHighlights) {
        guard value != highlights else { return }
        highlights = value
        neural.reportsWords = value.needsWords && !LowPower.on
    }

    var availableVoices: [TTSVoice] { synthesizer.availableVoices }

    func setVoice(_ identifier: String?) {
        synthesizer.config.voiceIdentifier = identifier
        tuning.chosenVoiceID = identifier
    }

    // MARK: - Highlights

    /// Whether the book is laid out as one long scrolling page.
    private var scrolls: Bool {
        (navigator as? EPUBNavigatorViewController)?.settings.scroll ?? false
    }

    /// `go` lands a followed locator at the very top of the screen, under the
    /// status bar. In a scrolling book, bring the spoken line to the middle
    /// instead — the painted line band when there is one (it sits at the exact
    /// line), else the word or sentence mark; with no mark painted, a page that
    /// the jump actually moved got its target put at the top, so shifting up
    /// half a screen centres it. A jump that didn't move the page means the
    /// spot is already visible and stays where the reader sees it.
    ///
    /// Readium's smooth scroll is fire-and-forget — `go` returns while the page
    /// is still moving — and a group container only enters the DOM a frame
    /// after its decoration is applied. Measuring right away reads a mid-flight
    /// scrollTop (the no-mark case would shift up half a screen from wherever
    /// the scroll happened to be) or finds no mark that a frame would have
    /// painted. So this waits, frame by frame, for the page to be still and
    /// (briefly) for a mark to show, then centres. ~1.5 s is the most it waits —
    /// a reader dragging the page keeps their scroll instead of being fought.
    ///
    /// The mark queried is the painted line, not the decoration's own wrapper:
    /// a group container holds a plain div per item, and that wrapper is static —
    /// it sits at the end of the document, so centring on it throws the page to
    /// the chapter's last screen. Only the absolutely-positioned children carry
    /// `data-writing-mode`, which picks the mark out of the wrapper.
    private func centerSpokenLine(on navigator: EPUBNavigatorViewController, pageWasAt before: Double) async {
        let script = """
        new Promise(function(resolve) {
          var mark = function() {
            return document.querySelector('[data-group="tts-line"] [data-writing-mode]')
                || document.querySelector('[data-group="tts-word"] [data-writing-mode]')
                || document.querySelector('[data-group="tts"] [data-writing-mode]');
          };
          var last = -1, still = 0, ticks = 0;
          (function tick() {
            var y = document.scrollingElement.scrollTop;
            still = Math.abs(y - last) < 1 ? still + 1 : 0;
            last = y;
            ticks += 1;
            var el = mark();
            if ((still >= 2 && (el || ticks > 18)) || ticks > 90) {
              if (el) {
                var r = el.getBoundingClientRect();
                window.scrollBy({ top: r.top + r.height / 2 - window.innerHeight / 2, behavior: 'smooth' });
              } else if (Math.abs(y - \(before)) > 1) {
                window.scrollBy({ top: -window.innerHeight / 2, behavior: 'smooth' });
              }
              return resolve();
            }
            requestAnimationFrame(tick);
          })();
        })
        """
        _ = await navigator.evaluateJavaScript(script)
    }

    /// If the voice has named no word of `sentence` in a moment, it won't: stop marking the first.
    private func waitForAWord(in sentence: Locator) {
        wordTimeout?.cancel()
        wordTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.spoken.sentence == sentence, self.namedAWordIn != sentence else { return }
            self.spoken.word = nil
        }
    }

    /// What is on the page now, so that only what changed is sent to it.
    private var painted: (sentence: [Decoration], line: [Decoration], word: [Decoration]) = ([], [], [])

    /// A mark's id names its chapter file as well as its group. Readium tells only the file a changed
    /// decoration is now in, so with one id throughout, the marks in the file the voice has just left would
    /// stay on its page (to be found when the reader turns back); with the file in the id, a move to
    /// another file is a removal there and an addition here.
    private func markID(_ group: String, _ locator: Locator) -> Decoration.Id {
        "\(group)-\(locator.href.string)"
    }

    /// Put the sentence, line and word being said on the page as chosen — and take away the rest.
    private func paint(_ spoken: Spoken, as highlights: ReadAloudHighlights, on navigator: DecorableNavigator) {
        var sentence: [Decoration] = [], line: [Decoration] = [], word: [Decoration] = []
        if highlights.sentence, let locator = spoken.sentence {
            sentence = [Decoration(id: markID("tts", locator), locator: locator.anchorable, style: .highlight(tint: .systemOrange))]
        }
        // Low Power Mode: the marks that move for every word — the word itself
        // and the line band it sits on — are the per-word cost; drop them both.
        if let locator = spoken.word, !spoken.wordIsTheSentence, !LowPower.on {
            if highlights.word {
                // a navigator that doesn't know the stronger mark gets the plain highlight
                let style: Decoration.Style = navigator.supports(decorationStyle: .spokenWord)
                    ? .spokenWord(tint: .systemOrange) : .highlight(tint: .systemOrange)
                word = [Decoration(id: markID("tts-word", locator), locator: locator.anchorable, style: style)]
            }
            if highlights.line, navigator.supports(decorationStyle: .spokenLine) {
                line = [Decoration(id: markID("tts-line", locator), locator: locator.anchorable, style: .spokenLine)]
            }
        }
        if sentence != painted.sentence {
            navigator.apply(decorations: sentence, in: "tts")
            painted.sentence = sentence
        }
        if line != painted.line {
            navigator.apply(decorations: line, in: "tts-line")
            painted.line = line
        }
        if word != painted.word {
            navigator.apply(decorations: word, in: "tts-word")
            painted.word = word
        }
    }

    /// Where the first word of a sentence is on the page: what is lit until the voice names a word.
    private func firstWord(of utterance: PublicationSpeechSynthesizer.Utterance) -> Locator? {
        guard let range = SpokenWords.words(in: utterance.text).first?.range else { return nil }
        return utterance.locator.copy(text: { text in
            guard let highlight = text.highlight, highlight.startIndex <= range.lowerBound, highlight.endIndex >= range.upperBound else { return }
            text = text[range]
        })
    }

    // MARK: - Lock screen / Control Center

    /// Call on every spoken sentence and pause: the estimate sharpens as the
    /// narration covers more of the book.
    private func noteProgression(_ locator: Locator) {
        let now = Date()
        if let deadline = sleepDeadline {
            sleepRemaining = max(0, deadline.timeIntervalSince(now))
        }
        if case .playing = synthesizer.state, let last = lastTickAt {
            playedSeconds += now.timeIntervalSince(last)
        }
        // key off the synthesizer, not isPlaying — a .paused delegate call arrives while
        // isPlaying still reads true (the pauseFlash hasn't flipped it), which would
        // count the whole pause as spoken time on the next sentence
        if case .playing = synthesizer.state { lastTickAt = now } else { lastTickAt = nil }
        guard let prog = locator.locations.totalProgression else { return }
        if startProgression == nil { startProgression = prog }
        currentProgression = prog
        // under ~0.2% read the ratio is mostly noise; past it, the estimate holds
        guard let start = startProgression, prog - start >= 0.002, playedSeconds >= 10 else { return }
        let whole = playedSeconds / (prog - start)
        if whole.isFinite { estimatedDuration = whole }
        estimatedRemaining = estimatedDuration.map { max($0 * (1 - prog), 0) }
    }

    /// The lock screen's title, author, cover and clock. Speech has no media
    /// file, so the timeline is the book: duration estimated from how far the
    /// narration has carried it, elapsed = where it is now. The buttons are
    /// `RemoteControls`'.
    private func publishNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: displayTitle,
            MPMediaItemPropertyArtist: displayAuthor,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentProgression * (estimatedDuration ?? 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
        ]
        if let estimatedDuration {
            info[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        }
        if let artworkItem { info[MPMediaItemPropertyArtwork] = artworkItem }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard artworkItem == nil, !artworkTried else { return }
        artworkTried = true
        Task { @MainActor in
            if let image = try? await publication.cover().get() {
                artworkItem = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                // only if read-aloud still has the lock screen
                if RemoteControls.shared.activeOwner == "readaloud" {
                    publishNowPlaying()
                }
            }
        }
    }
}

extension ReadAloud: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
            pauseFlash?.cancel()
            isPlaying = false
            lastTickAt = nil
            startProgression = nil
            playedSeconds = 0
            wordTimeout?.cancel()
            namedAWordIn = nil
            spoken = Spoken()
            pendingFollow = nil
        case let .playing(utterance, range: word):
            // a play task parked between sentences outlived a pause/stop's cancel and
            // reported playing once more — the engine refused to speak it (the composite
            // guards a cancelled speak), so hold the pause instead of reviving the controls
            if heldForFocus {
                synthesizer.pause()
                return
            }
            pauseFlash?.cancel()
            isActive = true
            isPlaying = true
            noteProgression(utterance.locator)
            publishNowPlaying()
            // the sentence, and in it the word being said — the first until the voice says which
            spoken = Spoken(sentence: utterance.locator, word: word ?? firstWord(of: utterance))
            if word != nil {
                namedAWordIn = utterance.locator
            } else {
                waitForAWord(in: utterance.locator)
            }
            if scrolls {
                followTarget.send(utterance.locator.anchorable)
            } else if let word {
                followTarget.send(word.anchorable)
            }
            // the state is published before every sentence, spoken or not — only a word being
            // spoken proves the voice works
            if let word {
                consecutiveFailures = 0
                #if DEBUG
                NSLog("PTReadAloud word %@", word.text.highlight ?? "?")
                #endif
            }
        case let .paused(utterance):
            pauseFlash?.cancel()
            pauseFlash = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                self.isPlaying = false
                self.publishNowPlaying()
                MPNowPlayingInfoCenter.default().playbackState = .paused
            }
            noteProgression(utterance.locator)
            // stays where it was if this is the sentence that was being said
            let stayed = spoken.sentence == utterance.locator ? spoken.word : nil
            spoken = Spoken(sentence: utterance.locator, word: stayed ?? firstWord(of: utterance))
        }
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        // A sentence the engine couldn't speak (e.g. no voice for its
        // language). Carry on — but if everything fails (a missing/broken
        // voice), an unconditional next() silently burned through the whole
        // book. Three in a row is enough — but before giving up, drop a
        // chosen voice for the automatic one: iOS lists premium voices that
        // were never downloaded, and they fail silently. Retrying the same
        // utterance with the default voice fixes that whole class.
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            if synthesizer.config.voiceIdentifier != nil {
                synthesizer.config.voiceIdentifier = nil
                tuning.chosenVoiceID = nil
                consecutiveFailures = 0
                onVoiceFallback?()
                synthesizer.start(from: utterance.locator)
                return
            }
            onError?("Read-aloud couldn't speak — the selected voice may not support this book's language.")
            Log.error("readaloud", "three utterances failed in a row even after the voice fallback — stopped")
            stop()
            return
        }
        synthesizer.next()
    }
}

extension EPUBNavigatorViewController {
    /// How far down its document the current page is scrolled, or nil when the
    /// page isn't there to answer.
    fileprivate func scrollTop() async -> Double? {
        (try? await evaluateJavaScript("document.scrollingElement.scrollTop").get()) as? Double
    }
}

extension Locator {
    /// Readium's content iterator bakes the parent element's CSS selector into every locator it
    /// makes (utterances, search hits), and the page anchors inside that element. A book whose ids
    /// a selector can't name — a leading digit, which Calibre gives every body — makes
    /// querySelector throw, so nothing is marked or scrolled to. The text anchor's before/after
    /// context finds the spot without it. Locators the page itself produces (selections, the
    /// first-visible-element locator) carry a proper JS-generated selector and keep it.
    var anchorable: Locator {
        copy(locations: { $0.otherLocations.removeValue(forKey: "cssSelector") })
    }
}
