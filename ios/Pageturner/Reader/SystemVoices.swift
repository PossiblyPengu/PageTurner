import AVFoundation
import SwiftUI

/// The voices iOS has installed, as `SpeechVoice`s.
enum SystemVoices {
    static func installed() -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().map(SpeechVoice.init(system:))
    }

    /// The installed voices worth reading a book with.
    static func readable() -> [SpeechVoice] {
        SpeechVoices.readable(installed())
    }

    /// What "Automatic" speaks with on this phone: the best downloaded voice for the
    /// device's language, else the system's own pick.
    static func automatic(for language: String? = nil) -> AVSpeechSynthesisVoice? {
        let tag = language ?? Locale.preferredLanguages.first
        if let better = SpeechVoices.upgrade(for: tag, among: installed(), preferred: Locale.preferredLanguages),
           let voice = AVSpeechSynthesisVoice(identifier: better.id)
        {
            return voice
        }
        return tag.flatMap { AVSpeechSynthesisVoice(language: $0) } ?? AVSpeechSynthesisVoice(language: nil)
    }
}

extension SpeechVoice {
    init(system voice: AVSpeechSynthesisVoice) {
        // the same ones Readium's own voice list leaves out
        let novelty = voice.voiceTraits.contains(.isNoveltyVoice)
            || voice.voiceTraits.contains(.isPersonalVoice)
            || voice.identifier.contains(".eloquence.")
            || voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
        let quality: Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        self.init(id: voice.identifier, name: voice.name, language: voice.language, quality: quality, isNovelty: novelty)
    }
}

/// Speaks a short sample so a voice can be heard before it is chosen — a voice iOS ships with,
/// or a neural one that has been downloaded.
@MainActor
final class SpeechPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// One for the whole app: a speech synthesizer must not be freed while iOS is still
    /// calling back into it (that crashes inside TextToSpeech), and only one sample plays at a time.
    static let shared = SpeechPreview()

    /// The sentence heard, in the voice's language.
    static func sample(for language: String?) -> String { SpeechSamples.text(for: language) }

    /// The voice being sampled — its identifier, or "" for Automatic.
    @Published private(set) var playing: String?

    private let synthesizer = AVSpeechSynthesizer()
    /// The system sample that was asked for last: a callback for an older one is not this one's end.
    private var current: AVSpeechUtterance?
    private var neuralTask: Task<Void, Never>?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Play the sample in `voice` (nil: Automatic) at `rate`; asking again for
    /// the voice that is playing stops it.
    func toggle(_ voice: SpeechVoice?, rate: Double) {
        let key = voice?.id ?? ""
        let wasPlaying = playing == key
        halt()
        guard !wasPlaying else { return release() }

        begin()
        let spoken = voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) } ?? SystemVoices.automatic()
        let utterance = AVSpeechUtterance(string: Self.sample(for: voice?.language ?? spoken?.language))
        utterance.voice = spoken
        utterance.rate = SpeechRateMap.avRate(forMultiplier: rate)
        current = utterance
        playing = key
        synthesizer.speak(utterance)
    }

    /// The same for a neural voice, which must be on this iPhone — `sid` hears one
    /// speaker of a multi-speaker voice.
    func toggle(_ voice: NeuralVoice, rate: Double, sid: Int = 0) {
        let key = voice.id(withSpeaker: sid)
        let wasPlaying = playing == key
        halt()
        guard !wasPlaying, let entry = NeuralVoiceStore.shared.index.entry(forID: key) else { return release() }

        begin()
        playing = key
        neuralTask = Task { [weak self] in
            if let audio = try? await NeuralSynth.shared.generate(
                text: Self.sample(for: voice.language), directory: entry.directory, info: entry.info, sid: entry.sid),
               !Task.isCancelled
            {
                NeuralPlayer.shared.speed = rate
                _ = await withTaskCancellationHandler {
                    await NeuralPlayer.shared.play(audio.samples, sampleRate: audio.sampleRate)
                } onCancel: {
                    Task { @MainActor in NeuralPlayer.shared.stop() }
                }
            }
            guard !Task.isCancelled else { return }
            self?.playing = nil
            self?.release()
        }
    }

    func stop() {
        guard playing != nil else { return }
        halt()
        release()
    }

    /// Silence whatever is playing, leaving the audio session as it is.
    private func halt() {
        guard playing != nil else { return }
        playing = nil
        current = nil
        neuralTask?.cancel()   // which also silences the player
        neuralTask = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: Audio session

    /// An audiobook or read-aloud in progress gives way, and the sound is allowed on the silent switch.
    private func begin() {
        AudioFocus.shared.register("preview", pause: { [weak self] in self?.stop() })
        AudioFocus.shared.claim("preview")
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    /// Let other apps' audio carry on — unless an audiobook or read-aloud of ours is still open.
    private func release() {
        AudioFocus.shared.unregister("preview")
        guard AudioFocus.shared.isIdle, playing == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    private func ended(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        playing = nil
        release()
    }
}
