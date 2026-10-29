import Foundation
import SherpaOnnx

/// Runs a downloaded neural voice on sherpa-onnx (Piper's VITS models on ONNX Runtime). The
/// model is loaded when first asked for and dropped after a quiet spell; all of it happens on
/// one serial queue, off the main thread — a sentence takes a fraction of a second to make.
final class NeuralSynth: @unchecked Sendable {
    static let shared = NeuralSynth()

    struct Audio {
        var samples: [Float]
        var sampleRate: Double
    }

    enum Failure: Error, LocalizedError {
        case missingFiles
        case loadFailed
        case silent

        var errorDescription: String? {
            switch self {
            case .missingFiles: return "The voice’s files are missing — download it again."
            case .loadFailed: return "The voice couldn’t be loaded."
            case .silent: return "The voice made no sound for that text."
            }
        }
    }

    private let queue = DispatchQueue(label: "io.github.possiblypengu.pageturner.neural", qos: .userInitiated)
    private var loaded: (key: String, tts: SherpaOnnxOfflineTtsWrapper)?
    private var unloadWork: DispatchWorkItem?

    /// How long a model stays in memory after it was last used.
    private let keepAlive: TimeInterval = 45

    /// Speech for `text` in the voice at `directory` (see `NeuralVoiceFormat.install`) at its
    /// natural pace — `sid` picks a speaker of a multi-speaker voice.
    func generate(text: String, directory: URL, info: NeuralVoiceFormat.Installed, sid: Int = 0) async throws -> Audio {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // abandoned while it waited its turn (a skip): don't spend the queue on it
                    if cancelled.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        continuation.resume(returning: try self.run(text: text, directory: directory, info: info, sid: sid))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Load the voice's model now, so the first sentence asked for doesn't wait for it.
    /// Best-effort: a model that can't be loaded is found out when a sentence is made, as before.
    func warm(directory: URL, info: NeuralVoiceFormat.Installed) {
        queue.async {
            self.unloadWork?.cancel()
            if self.loaded?.key != info.key {
                self.loaded = (info.key, try? self.load(directory: directory, info: info))
                if self.loaded?.tts == nil { self.loaded = nil }
            }
            // a warmed model that never sees a sentence gives its memory back on the usual timer
            if self.loaded != nil { self.scheduleUnload() }
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// Let go of the model now (a memory warning, or the last sentence has been read).
    func unload() {
        queue.async {
            self.unloadWork?.cancel()
            self.loaded = nil
        }
    }

    // MARK: On the queue

    private func run(text: String, directory: URL, info: NeuralVoiceFormat.Installed, sid: Int) throws -> Audio {
        unloadWork?.cancel()
        if loaded?.key != info.key {
            loaded = nil   // free the old one before the new one is made
            let tts = try load(directory: directory, info: info)
            loaded = (info.key, tts)
        }
        guard let tts = loaded?.tts else { throw Failure.loadFailed }

        // sherpa turns a speed into length_scale = 1 / speed and then forgets the voice's own
        // length_scale, so ask for the pace the voice was made for. Faster or slower is the
        // player's job: stretching the audio is more exact than VITS's rounded durations.
        let speaker = max(0, min(sid, info.speakers - 1))
        let generated = tts.generate(text: text, sid: Int32(speaker), speed: Float(1 / max(info.lengthScale, 0.1)))
        let samples = generated.samples
        scheduleUnload()
        guard !samples.isEmpty, generated.sampleRate > 0 else { throw Failure.silent }
        return Audio(samples: samples, sampleRate: Double(generated.sampleRate))
    }

    private func load(directory: URL, info: NeuralVoiceFormat.Installed) throws -> SherpaOnnxOfflineTtsWrapper {
        let fm = FileManager.default
        let model = directory.appendingPathComponent(NeuralVoiceFormat.modelFile).path
        let tokens = directory.appendingPathComponent(NeuralVoiceFormat.tokensFileName).path
        // the phoneme data for every language espeak-ng knows, bundled with the app
        guard let espeak = Bundle.main.url(forResource: "espeak-ng-data", withExtension: nil)?.path,
              fm.fileExists(atPath: model), fm.fileExists(atPath: tokens)
        else { throw Failure.missingFiles }

        return try withExtendedLifetime((model, tokens, espeak)) { () throws -> SherpaOnnxOfflineTtsWrapper in
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: model, lexicon: "", tokens: tokens, dataDir: espeak,
                noiseScale: info.noiseScale, noiseScaleW: info.noiseW, lengthScale: 1)
            // Low Power Mode halves the synthesis threads — VITS still clears real time
            let modelConfig = sherpaOnnxOfflineTtsModelConfig(
                vits: vits, numThreads: LowPower.on ? 1 : 2, debug: 0, provider: "cpu")
            var config = sherpaOnnxOfflineTtsConfig(model: modelConfig, ruleFsts: "", maxNumSentences: 1)
            let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard tts.tts != nil else { throw Failure.loadFailed }
            return tts
        }
    }

    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in self?.loaded = nil }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + keepAlive, execute: work)
    }
}
