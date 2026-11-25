import Foundation
import SherpaOnnx

/// Runs a downloaded neural voice on sherpa-onnx (Piper's VITS models on ONNX Runtime). The
/// model is loaded when first asked for and dropped after a quiet spell; all of it happens on
/// one serial queue, off the main thread — a sentence takes a fraction of a second to make.
final class NeuralSynth: @unchecked Sendable {
    static let shared = NeuralSynth()

    struct Audio: Sendable {
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

    /// A sentence made ahead of its turn is made at a low priority, so that it does not take the processor from the
    /// page (a turn, a mark) while there is still sound queued; one that is waited for is made at once. The queue
    /// itself is the low one — a block can ask for more than its queue's priority, never for less.
    private let queue = DispatchQueue(label: "io.github.possiblypengu.pageturner.neural", qos: .utility)
    private var loaded: (key: String, tts: SherpaOnnxOfflineTtsWrapper)?
    /// Sentences made with the model now loaded. ONNX Runtime keeps memory it grew for one length of sentence to
    /// reuse for the next, and over hours of every length that only climbs; a fresh load every so often hands it
    /// back (the lookahead makes the next sentence while one is said, so the reload is not heard).
    private var madeWithModel = 0
    private let reloadEvery = 150
    private var unloadWork: DispatchWorkItem?

    /// How long a model stays in memory after it was last used.
    private let keepAlive: TimeInterval = 45

    /// What the loaded model was made from, so it can be loaded again with more threads (`needsMoreThreads`).
    private var loadedFrom: (directory: URL, info: NeuralVoiceFormat.Installed)?
    private var loadedThreads = 1

    // What making speech has cost lately, for the log (`noteCost`) — kept on the queue.
    private var costSentences = 0
    private var costAhead = 0
    private var costCompute: Double = 0
    private var costAudio: Double = 0

    /// Speech for `text` in the voice at `directory` (see `NeuralVoiceFormat.install`) at its
    /// natural pace — `sid` picks a speaker of a multi-speaker voice.
    /// `ahead`: nobody is waiting for it yet (see `hurry`).
    func generate(
        text: String, directory: URL, info: NeuralVoiceFormat.Installed, sid: Int = 0, ahead: Bool = false,
        pace: Double = 1
    ) async throws -> Audio {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: ahead ? .utility : .userInitiated, flags: ahead ? [] : .enforceQoS) {
                    // abandoned while it waited its turn (a skip): don't spend the queue on it
                    if cancelled.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        continuation.resume(returning: try self.run(
                            text: text, directory: directory, info: info, sid: sid, ahead: ahead, pace: pace))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// What is being made ahead is now waited for (or soon will be): the queue is serial, so something urgent put
    /// behind the sentence being made lends it its priority until it is done.
    func hurry() {
        queue.async(qos: .userInitiated, flags: .enforceQoS) {}
    }

    /// Load the voice's model now, so the first sentence asked for doesn't wait for it.
    /// Best-effort: a model that can't be loaded is found out when a sentence is made, as before.
    func warm(directory: URL, info: NeuralVoiceFormat.Installed) {
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            self.unloadWork?.cancel()
            if self.loaded?.key != info.key {
                self.loaded = nil
                if let tts = try? self.load(directory: directory, info: info) {
                    self.loaded = (info.key, tts)
                }
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

    private func run(
        text: String, directory: URL, info: NeuralVoiceFormat.Installed, sid: Int, ahead: Bool, pace: Double = 1
    ) throws -> Audio {
        unloadWork?.cancel()
        if loaded?.key != info.key {
            loaded = nil   // free the old one before the new one is made
            let tts = try load(directory: directory, info: info)
            loaded = (info.key, tts)
            madeWithModel = 0
        }
        guard let tts = loaded?.tts else { throw Failure.loadFailed }

        // the voice's own pace, or faster (`NeuralPace`: the sound made is what it costs, and the player stretches by
        // whatever the voice did not reach)
        let speaker = max(0, min(sid, info.speakers - 1))
        let began = DispatchTime.now().uptimeNanoseconds
        let speed = NeuralPace.sherpaSpeed(pace: pace, lengthScale: Double(info.lengthScale))
        let generated = tts.generate(text: text, sid: speaker, speed: Float(speed))
        let samples = generated.samples
        if generated.sampleRate > 0 {
            let compute = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            noteCost(compute: compute, audio: Double(samples.count) / Double(generated.sampleRate), ahead: ahead, key: info.key)
        }
        madeWithModel += 1
        if madeWithModel >= reloadEvery {
            // dropped now (after this sentence is made); the next sentence loads it afresh
            loaded = nil
            madeWithModel = 0
            Log.event("neural", "voice model reloaded after \(reloadEvery) sentences, to give its memory back")
        }
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
            let threads = self.threads(for: info.key)
            let modelConfig = sherpaOnnxOfflineTtsModelConfig(
                vits: vits, numThreads: threads, debug: 0, provider: "cpu")
            var config = sherpaOnnxOfflineTtsConfig(model: modelConfig, ruleFsts: "", maxNumSentences: 1)
            let began = DispatchTime.now().uptimeNanoseconds
            let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard tts.tts != nil else { throw Failure.loadFailed }
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            self.loadedFrom = (directory, info)
            self.loadedThreads = threads
            let on = threads == 1 ? "one thread" : String(threads) + " threads"
            Log.event("neural", "voice \(info.key) loaded in \(ms) ms, \(on)")
            return tts
        }
    }

    // MARK: Threads, and what it costs

    /// How many threads ONNX Runtime makes a voice's sentences with. One, unless the voice has shown it cannot keep up
    /// on one (`needsMoreThreads`) — and never more in Low Power Mode.
    ///
    /// Two threads were the rule, and they cost more than they gave: ONNX Runtime's second thread spins rather than
    /// sleeps while it waits between the model's many small steps, so two threads can burn up to twice the processor
    /// time of one for well under twice the speed — and a thread the queue does not run cannot be held to its priority, so what was
    /// made ahead "at leisure" still ran on the fast, power-hungry cores. On one thread every step runs on the queue's
    /// own thread, at the queue's priority: a sentence made ahead can go to the efficiency cores, and `hurry` lifts it
    /// when it is needed.
    private func threads(for key: String) -> Int {
        if LowPower.on { return 1 }
        return UserDefaults.standard.integer(forKey: Self.threadsKey(key)) >= 2 ? 2 : 1
    }

    private static func threadsKey(_ key: String) -> String { "neural-threads-" + key }

    /// The voice could not keep up on one thread: sentences made ahead were still being made when they were needed,
    /// with time to spare to make them. It is given two from now on (remembered per voice), loaded again at once.
    func needsMoreThreads(forKey key: String) {
        queue.async(qos: .userInitiated) {
            guard !LowPower.on, UserDefaults.standard.integer(forKey: Self.threadsKey(key)) < 2 else { return }
            UserDefaults.standard.set(2, forKey: Self.threadsKey(key))
            Log.event("neural", "voice \(key) could not keep up on one thread — it uses two from now on")
            guard self.loaded?.key == key, let from = self.loadedFrom else { return }
            self.loaded = nil
            if let tts = try? self.load(directory: from.directory, info: from.info) {
                self.loaded = (key, tts)
                self.madeWithModel = 0
            }
        }
    }

    /// Every hundred sentences, the log says how hard the voice works: seconds of speech made per second of
    /// processor time, how many were made ahead of their turn, and on how many threads. 0.3 of real time is a voice
    /// that is busy a third of the time it speaks.
    private func noteCost(compute: Double, audio: Double, ahead: Bool, key: String) {
        costSentences += 1
        if ahead { costAhead += 1 }
        costCompute += compute
        costAudio += audio
        guard costSentences >= 100 else { return }
        let share = String(format: "%.2f", costAudio > 0 ? costCompute / costAudio : 0)
        let on = loadedThreads == 1 ? "one thread" : String(loadedThreads) + " threads"
        let power = LowPower.on ? ", Low Power Mode" : ""
        let line = "voice \(key): \(costSentences) sentences, \(Int(costAudio)) s of speech made in \(Int(costCompute)) s "
            + "(\(share) of real time), \(costAhead) made ahead, \(on)\(power)"
        Log.event("neural", line)
        costSentences = 0
        costAhead = 0
        costCompute = 0
        costAudio = 0
    }

    // MARK: Faster paces

    private static func paceKey(_ key: String, _ pace: Double) -> String {
        "neural-pace-" + key + "-" + String(Int((pace * 100).rounded()))
    }

    /// How much faster a sentence made at `pace` really is, measured for this voice (`calibrate`); nil until it has
    /// been, or when the pace made no worthwhile difference (stored as 1).
    func achieved(pace: Double, key: String) -> Double? {
        let stored = UserDefaults.standard.double(forKey: Self.paceKey(key, pace))
        return stored > 1 ? stored : nil
    }

    /// Paces being measured now, so one is not measured twice at once (on the queue).
    private var calibrating: Set<String> = []

    /// Measure once what `pace` really gives this voice: a sample in its language made at its own pace and at `pace`,
    /// at low priority, behind whatever is being made. Until it is done, sentences are made at the voice's own pace.
    func calibrate(pace: Double, directory: URL, info: NeuralVoiceFormat.Installed, language: String) {
        let key = Self.paceKey(info.key, pace)
        queue.async(qos: .utility) {
            guard UserDefaults.standard.object(forKey: key) == nil, !self.calibrating.contains(key) else { return }
            self.calibrating.insert(key)
            defer { self.calibrating.remove(key) }
            // twice over: a longer sample evens out the rounding of each sound's length
            let sample = SpeechSamples.text(for: language)
            let text = sample + " " + sample
            guard let natural = try? self.run(text: text, directory: directory, info: info, sid: 0, ahead: true),
                  let faster = try? self.run(text: text, directory: directory, info: info, sid: 0, ahead: true, pace: pace)
            else { return }
            let measured = NeuralPace.achieved(
                natural: Double(natural.samples.count) / natural.sampleRate,
                made: Double(faster.samples.count) / faster.sampleRate, asked: pace)
            // 1: measured, and not worth it — not measured again
            UserDefaults.standard.set(measured ?? 1, forKey: key)
            let got = measured.map { String(format: "%.2f×", $0) } ?? "no faster"
            let asked = String(format: "%.2f×", pace)
            Log.event("neural", "voice \(info.key) asked for \(asked) speaks \(got)")
        }
    }

    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in self?.loaded = nil }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + keepAlive, execute: work)
    }
}
