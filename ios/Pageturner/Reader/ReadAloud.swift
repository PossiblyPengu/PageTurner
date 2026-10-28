import AVFoundation
import Combine
import MediaPlayer
import ReadiumNavigator
import ReadiumShared
import UIKit

/// Tunes every utterance a system voice is asked to say (the engines have no rate
/// setting, and asking iOS for "a voice for this language" answers with the compact
/// default even when a better one is installed).
final class SpeechTuning: AVTTSEngineDelegate {
    /// 1 = the voice's normal pace.
    var multiplier: Double = 1.0
    /// The voice the reader picked, if any: the one thing never to second-guess.
    var chosenVoiceID: String?
    private lazy var installed = SystemVoices.installed()

    /// Readium's own engine handed its utterances here; `SystemTTSEngine` calls `tune` directly.
    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        tune(utterance)
    }

    func tune(_ utterance: AVSpeechUtterance) {
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
    /// Where a paged book is turned to, to follow the narration: the word being said.
    private let followTarget = PassthroughSubject<Locator, Never>()
    /// The sentence being said in a scrolling book, sent with every word: the page is kept with the spoken line
    /// (`followScrolling`), not jumped to each sentence.
    private let scrollNudge = PassthroughSubject<Locator, Never>()
    /// The last sentence a scrolling book was jumped to, so a page with no mark to measure is not jumped again with
    /// every word of it.
    private var scrolledTo: Locator?
    /// The reader has scrolled a scrolling book away from the line being said: the page is left where they put it,
    /// and the reader shows "Back to Narration" (`resumeFollowing`). Scrolling back to the line lets go of it too.
    @Published private(set) var followHeld = false
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
    /// Called for each sentence begun while the page is not on screen — the narration has carried the reader's
    /// place to it, and nothing else will say so.
    var onNarrated: ((Locator) -> Void)?
    /// The page is in front of the reader. Left (to another tab, or the library) the narration goes on, but
    /// nothing is chased, painted or measured per word on a page nobody sees; coming back catches the page up.
    private(set) var onScreen = true
    private var lastNarrated: Locator?

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
            engineFactory: { CompositeTTSEngine(system: SystemTTSEngine(tuning: tuning), neural: neural) },
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
                    guard let self, self.onScreen else { return }
                    self.paint(spoken, as: highlights, on: decorable)
                }
                .store(in: &subscriptions)
            // iOS toggling Low Power Mode mid-book adds or drops the word marks
            // on the next repaint rather than the next open
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: LowPower.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateWordReporting()
                    if self.onScreen { self.paint(self.spoken, as: self.highlights, on: decorable) }
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

        // follow the narration, turning pages mid-sentence when needed. The main queue, not the run loop: a
        // run-loop timer in the default mode stalls while a finger is on the page.
        followTarget
            .removeDuplicates()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] locator in
                guard let self, self.onScreen else { return }
                self.pendingFollow = locator
                self.follow()
            }
            .store(in: &subscriptions)
        // a scrolling book keeps the spoken line on screen as it moves down the page
        scrollNudge
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] sentence in
                guard let self, self.onScreen else { return }
                self.followScrolling(sentence)
            }
            .store(in: &subscriptions)
    }

    // MARK: - Following

    /// Turn the page to `pendingFollow`, newest target first. The navigator
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
                if await navigator.go(to: locator, options: NavigatorGoOptions(animated: true)) {
                    attempts = 0
                } else {
                    pendingFollow = pendingFollow ?? locator
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            isTurning = false
        }
    }

    /// A scrolling book: keep the line being said on screen. While the voice is in the chapter on screen the page
    /// is only nudged — when the spoken line nears the top or bottom it is brought up to a little above the middle,
    /// so the page moves in steps the eye can follow rather than with every sentence. A reader who has just
    /// touched the page is left where they are for a few seconds. The voice in another chapter (or no mark of it on
    /// this page) is jumped to, and the line then put in the middle.
    ///
    /// Readium's `evaluateJavaScript` hands back what a script returns there and then — it does not wait for a
    /// promise — so the script measures and scrolls in one go, and the waiting for a mark to be painted is done here.
    private func followScrolling(_ sentence: Locator, recenter: Bool = false) {
        guard !isTurning, let epub = navigator as? EPUBNavigatorViewController else { return }
        isTurning = true
        Task { @MainActor in
            defer { isTurning = false }
            if epub.currentLocation?.href.isEquivalentTo(sentence.href) == true {
                for attempt in 0 ..< 3 {
                    // a mark is painted a frame or two after the voice moves on
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
                    switch await keepSpokenInView(on: epub, center: recenter) {
                    case "none": continue
                    case "held": followHeld = true; return
                    case "wait": return
                    default: followHeld = false; return
                    }
                }
            }
            // a reader who has scrolled away is not taken to the next chapter either
            guard !followHeld || recenter else { return }
            guard sentence != scrolledTo, let place = sentence.followable,
                  await epub.go(to: place, options: NavigatorGoOptions(animated: false))
            else { return }
            scrolledTo = sentence
            followHeld = false
            for _ in 0 ..< 10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await keepSpokenInView(on: epub, center: true) != "none" { return }
            }
            // no mark to measure (every highlight is off): `go` left the sentence at the very top
            _ = await epub.evaluateJavaScript("window.scrollBy({ top: -window.innerHeight * 0.4 })")
        }
    }

    /// "Back to Narration": the page goes to the line being said, and follows it again.
    func resumeFollowing() {
        followHeld = false
        guard let sentence = spoken.sentence else { return }
        scrolledTo = nil
        followScrolling(sentence, recenter: true)
    }

    /// The spoken line's mark, measured and — if it is near an edge, or `center` asks — scrolled to 40% down the
    /// screen. Answers "none" (no mark on this page), "held" (the reader has scrolled the page off the spoken line),
    /// "wait" (they are on it, finger still busy), "moved" or "shown". The mark queried is the painted line, not the decoration's own wrapper: a group container holds a
    /// plain div per item that sits at the end of the document; only the absolutely-positioned children carry
    /// `data-writing-mode`.
    private func keepSpokenInView(on navigator: EPUBNavigatorViewController, center: Bool) async -> String {
        let script = """
        (function() {
          var w = window;
          if (!w.__ptFollow) {
            w.__ptFollow = { touched: 0 };
            var note = function() { w.__ptFollow.touched = Date.now(); };
            ['touchstart', 'touchmove', 'touchend'].forEach(function(name) {
              document.addEventListener(name, note, { passive: true, capture: true });
            });
          }
          var el = document.querySelector('[data-group="tts-line"] [data-writing-mode]')
                || document.querySelector('[data-group="tts-word"] [data-writing-mode]')
                || document.querySelector('[data-group="tts"] [data-writing-mode]');
          if (!el) { return 'none'; }
          var center = \(center ? "true" : "false");
          var h = window.innerHeight, r = el.getBoundingClientRect(), mid = r.top + r.height / 2;
          if (center) {
            w.__ptFollow.resumed = Date.now();
          } else if (w.__ptFollow.touched > (w.__ptFollow.resumed || 0)) {
            // the reader has moved the page: off the spoken line, it stays where they put it; back on it (and the
            // finger lifted a moment), following takes over again
            if (mid < h * 0.1 || mid > h * 0.9) { return 'held'; }
            if (Date.now() - w.__ptFollow.touched < 1500) { return 'wait'; }
            w.__ptFollow.resumed = Date.now();
          }
          if (center || mid < h * 0.15 || mid > h * 0.7) {
            window.scrollBy({ top: mid - h * 0.4, behavior: center ? 'auto' : 'smooth' });
            return 'moved';
          }
          return 'shown';
        })()
        """
        return ((try? await navigator.evaluateJavaScript(script).get()) as? String) ?? "none"
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
        updateWordReporting()
    }

    /// Per-word work is for a page that is looked at: not in Low Power Mode, and not with the reader left.
    private func updateWordReporting() {
        neural.reportsWords = onScreen && highlights.needsWords && !LowPower.on
    }

    /// The reader was left with the narration going on, or came back to it.
    func setOnScreen(_ shown: Bool) {
        guard shown != onScreen else { return }
        onScreen = shown
        updateWordReporting()
        if !shown {
            // a jump in flight is a jump nobody will see
            pendingFollow = nil
            lastNarrated = nil
            return
        }
        guard isActive else { return }
        // the marks and the page catch up to what is being said now
        if let decorable { paint(spoken, as: highlights, on: decorable) }
        if scrolls {
            if let sentence = spoken.sentence {
                scrolledTo = nil
                followHeld = false
                followScrolling(sentence, recenter: true)
            }
        } else if let place = (spoken.word ?? spoken.sentence)?.followable {
            pendingFollow = place
            follow()
        }
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
            sentence = [Decoration(id: markID("tts", locator), locator: locator.paintable, style: .highlight(tint: .systemOrange))]
        }
        // Low Power Mode: the marks that move for every word — the word itself
        // and the line band it sits on — are the per-word cost; drop them both.
        if let locator = spoken.word, !spoken.wordIsTheSentence, !LowPower.on {
            if highlights.word {
                // a navigator that doesn't know the stronger mark gets the plain highlight
                let style: Decoration.Style = navigator.supports(decorationStyle: .spokenWord)
                    ? .spokenWord(tint: .systemOrange) : .highlight(tint: .systemOrange)
                word = [Decoration(id: markID("tts-word", locator), locator: locator.paintable, style: style)]
            }
            if highlights.line, navigator.supports(decorationStyle: .spokenLine) {
                line = [Decoration(id: markID("tts-line", locator), locator: locator.paintable, style: .spokenLine)]
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
            scrolledTo = nil
            followHeld = false
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
            if !onScreen {
                // the state comes with every word: the reader's place moves with the sentence
                if utterance.locator != lastNarrated {
                    lastNarrated = utterance.locator
                    onNarrated?(utterance.locator)
                }
            } else if scrolls {
                scrollNudge.send(utterance.locator)
            } else if let word {
                if let place = word.followable { followTarget.send(place) }
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

extension Locator {
    /// Readium's content iterator bakes the parent element's CSS selector into every locator it
    /// makes (utterances, search hits), and the page anchors inside that element: the text search
    /// for the sentence or word stays within it. A book whose ids a selector can't name — a leading
    /// digit, which Calibre gives every body — makes querySelector throw, so nothing is marked or
    /// scrolled to; the selector used to be dropped for that, which sent every anchor to a fuzzy
    /// search of the whole chapter — and a sentence the page spells a little differently (a
    /// line break, a bullet, an entity) was "found" twenty screens away, where the page then went
    /// for a moment on every such sentence. Now the selector is kept, repaired so the page can
    /// parse it (`CSSSelectorRepair`). Locators the page itself produces (selections, the
    /// first-visible-element locator) carry a proper JS-generated selector and are left alone.
    /// A word or sentence with nothing of its own text around it — a speaker's name on a line by itself, "No." — is
    /// found by its text alone, and without a selector the first one of those in the chapter is where a text search lands.
    var isLonely: Bool {
        (text.before ?? "").isEmpty && (text.after ?? "").isEmpty
    }

    /// Whether the page can be told which element to look in.
    var hasSelector: Bool {
        locations.otherLocations["cssSelector"]?.string != nil
    }

    /// What the page is taken to, or nil to leave it where it is: a lonely locator with no element to look in
    /// would take the page back to the first place that text appears in the chapter (and the next sentence takes
    /// it on from there). A lone line is all but always on the page already.
    var followable: Locator? {
        isLonely && !hasSelector ? nil : anchorable
    }

    /// What a mark is painted at: the text, looked for inside the element it came from.
    var paintable: Locator {
        anchorable
    }

    var anchorable: Locator {
        copy(locations: { locations in
            guard let selector = locations.otherLocations["cssSelector"]?.string else { return }
            locations.otherLocations["cssSelector"] = .string(CSSSelectorRepair.repaired(selector))
        })
    }
}
