import AVFoundation
import ReadiumNavigator
import ReadiumShared

/// iOS's own voices, through Readium's TTSEngine. Readium's AVTTSEngine speaks exactly the text it
/// is handed, and TTSUtterance can't be rebuilt (no public init) — so this engine exists to speak
/// the cleaned text (`SpeechText.spoken`) while reporting word ranges in the page's own, which is
/// what the locator carries. iOS 17 has none of the iOS 15 queueing deadlock Readium's state machine
/// guards against, so one utterance at a time through one synthesizer is enough.
///
/// The synthesizer is one long-lived object: a synthesizer freed while iOS is still calling back
/// into it crashes inside TextToSpeech (the `SpeechPreview.shared` note in AGENTS.md).
final class SystemTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    /// Tunes each utterance before it is spoken — rate, and the automatic-voice upgrade.
    let tuning: SpeechTuning

    private static let synthesizer = AVSpeechSynthesizer()
    /// The engine the shared synthesizer's callbacks belong to — weak, like `delegate` itself.
    @MainActor private static weak var current: SystemTTSEngine?

    /// One utterance through the shared synthesizer: the text iOS says (`spoken`), the page's own
    /// text the locator carries (`original`), where a reported word range goes, and the
    /// continuation, resumed exactly once.
    private final class Flight {
        let utterance: AVSpeechUtterance
        let original: String
        let spoken: String
        let onSpeakRange: (Range<String.Index>) -> Void
        var continuation: CheckedContinuation<Result<Void, TTSError>, Never>?
        var cancelled = false

        init(utterance: AVSpeechUtterance, original: String, spoken: String,
             onSpeakRange: @escaping (Range<String.Index>) -> Void) {
            self.utterance = utterance
            self.original = original
            self.spoken = spoken
            self.onSpeakRange = onSpeakRange
        }

        /// A finish and a cancel both read as success — like AVTTSEngine's didCancel→finished, the
        /// caller's own `Task.isCancelled` is what tells a stopped sentence from a done one.
        func finish() {
            continuation?.resume(returning: .success(()))
            continuation = nil
        }
    }

    @MainActor private var flight: Flight?

    init(tuning: SpeechTuning) {
        self.tuning = tuning
        super.init()
    }

    /// The voices iOS offers for reading — the same ones Readium's AVTTSEngine lists (novelty,
    /// personal, eloquence and the old "classic" voices are left out).
    var availableVoices: [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.voiceTraits.contains(.isPersonalVoice)
                    && !voice.identifier.contains(".eloquence.")
                    && !voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
            }
            .map(TTSVoice.init(system:))
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        AVSpeechSynthesisVoice(identifier: identifier).map(TTSVoice.init(system:))
    }

    @MainActor
    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        guard !Task.isCancelled else { return .success(()) }
        let original = utterance.text
        let spoken = SpeechText.spoken(original)
        // a segment the voice would say nothing for (a running page number) is dropped
        guard !spoken.isEmpty else { return .success(()) }

        let av = AVSpeechUtterance(string: spoken)
        av.preUtteranceDelay = utterance.delay
        switch utterance.voiceOrLanguage {
        case let .left(voice):
            av.voice = AVSpeechSynthesisVoice(identifier: voice.identifier)
        case let .right(language):
            av.voice = AVSpeechSynthesisVoice(language: language.code.bcp47)
        }
        tuning.tune(av)

        // nothing should still be in flight — but end whatever is, rather than leak its await
        if let old = flight {
            old.finish()
            Self.synthesizer.stopSpeaking(at: .immediate)
        }
        let flight = Flight(utterance: av, original: original, spoken: spoken, onSpeakRange: onSpeakRange)
        self.flight = flight
        Self.current = self
        Self.synthesizer.delegate = self

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                flight.continuation = continuation
                Self.synthesizer.speak(av)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelCurrent() }
        }
    }

    /// A cancelled speak: mark the flight so a word report already on its way is dropped (Readium's
    /// own Task.onSpeakRange guards the same way) and take the sound off — `didCancel` then ends it.
    @MainActor
    private func cancelCurrent() {
        flight?.cancelled = true
        Self.synthesizer.stopSpeaking(at: .immediate)
    }

    /// A finish or a cancel ends the flight it belongs to; a callback for anything else (the tail
    /// of an earlier utterance) is ignored.
    @MainActor
    private func end(_ utterance: AVSpeechUtterance) {
        guard let flight, utterance === flight.utterance else { return }
        self.flight = nil
        if Self.current === self { Self.current = nil }
        flight.finish()
    }

    /// A word's range lands on the cleaned string iOS was given — put it back on the page's text,
    /// or the whole sentence when the word has no counterpart there.
    @MainActor
    private func report(_ characterRange: NSRange, of utterance: AVSpeechUtterance) {
        guard let flight, utterance === flight.utterance, !flight.cancelled,
              let range = Range(characterRange, in: flight.spoken)
        else { return }
        flight.onSpeakRange(
            SpeechText.originalRange(of: range, spoken: flight.spoken, original: flight.original)
                ?? flight.original.startIndex ..< flight.original.endIndex)
    }

    // MARK: AVSpeechSynthesizerDelegate — iOS calls these on its own thread, so they hop to the
    // main actor where the flight lives (the strong `self` keeps the engine alive for the callback).

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(utterance) }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance avUtterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.report(characterRange, of: avUtterance) }
    }
}

private extension TTSVoice {
    /// The same map Readium's AVTTSEngine applies to an installed voice — its own `init(voice:)`
    /// is private to it, so this mirrors it (compact/super-compact told apart by the identifier).
    init(system voice: AVSpeechSynthesisVoice) {
        let gender: Gender
        switch voice.gender {
        case .male: gender = .male
        case .female: gender = .female
        case .unspecified: gender = .unspecified
        @unknown default: gender = .unspecified
        }
        let quality: Quality?
        switch voice.quality {
        case .default:
            if voice.identifier.contains(".compact.") {
                quality = .low
            } else if voice.identifier.contains(".super-compact.") {
                quality = .lower
            } else {
                quality = .medium
            }
        case .enhanced: quality = .high
        case .premium: quality = .higher
        @unknown default: quality = nil
        }
        self.init(
            identifier: voice.identifier,
            language: Language(code: .bcp47(voice.language)),
            name: voice.name,
            gender: gender,
            quality: quality)
    }
}
