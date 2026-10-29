import AVFoundation

/// Plays synthesized speech through AVAudioEngine at a speed that can change while it plays. The
/// audio is time-stretched rather than re-synthesized: VITS rounds phoneme durations to whole
/// frames, so asking the model for "twice as fast" gets about 1.3×; stretching is exact and keeps
/// the voice's pitch.
///
/// Audio is scheduled in short pieces, so after an interruption (a call, a route change) it picks up
/// from the first piece not yet heard. `enqueue` waits for the sentence to be heard — or, given a
/// `lead`, returns while the end of it is still playing, so whoever is feeding the player can have the
/// next one ready — and says how far through the sentence the voice is while it plays, which is what
/// lights the word being spoken.
@MainActor
final class NeuralPlayer {
    static let shared = NeuralPlayer()

    private struct Piece {
        let id: Int
        let buffer: AVAudioPCMBuffer
    }

    private struct Waiter {
        let id: Int
        /// Resume once no more than this much playing time is left.
        let lead: TimeInterval
        let resume: (Bool) -> Void
    }

    /// Who is told how far the voice has got in the sentence it queued last.
    private struct Follower {
        /// Frames queued before this sentence's first.
        let start: Double
        let frames: Double
        let report: @MainActor (TimeInterval) -> Void
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let stretch = AVAudioUnitTimePitch()
    private var wiredRate: Double = 0

    /// Scheduled and not yet heard, oldest first.
    private var pending: [Piece] = []
    private var nextID = 0
    /// Bumped whenever the queue is rebuilt, so a callback for an old queue is ignored.
    private var generation = 0
    private var waiters: [Waiter] = []
    private var idleStop: Task<Void, Never>?
    private var recovery = AudioRecovery()

    // Where the voice is: frames queued and heard since the queue was last emptied, how far into the
    // piece being heard it is (integrated from the clock, and corrected each time a piece ends), and
    // the ticker that reads it out.
    private var clock = PlayheadClock()
    private var lastTick: Date?
    private var ticker: Task<Void, Never>?
    private var follower: Follower?

    /// 1 is the voice's own pace. Applies at once, even in the middle of a sentence.
    var speed: Double = 1 {
        didSet {
            stretch.rate = Float(min(max(speed, 0.25), 4))
            wake()   // the time left changes with the speed
        }
    }

    private init() {
        engine.attach(node)
        engine.attach(stretch)
        stretch.pitch = 0
        let center = NotificationCenter.default
        // the output changed under us (headphones out, a Bluetooth route): the engine has stopped
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pickUp() }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    self.recovery.beginInterruption()
                    self.node.pause()
                case .ended:
                    let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.recovery.endInterruption(shouldResume: resume)
                    if resume { self.pickUp() }
                    else { AudioFocus.shared.pauseAll(); self.stop() }
                @unknown default: break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                AudioFocus.shared.pauseAll()
                self?.stop()
            }
        }
    }

    // MARK: Playing

    /// Seconds of playing time still queued, at the current speed.
    var remaining: TimeInterval {
        guard wiredRate > 0 else { return 0 }
        let frames = clock.framesLeft(pending: pending.reduce(0.0) { $0 + Double($1.buffer.frameLength) })
        return frames / wiredRate / max(speed, 0.25)
    }

    /// Queue `samples` behind what is playing and wait until no more than `lead` seconds of it are
    /// left (0: until it has all been heard). True when that happened or `stop()` cut it short;
    /// false when the engine could not be started.
    ///
    /// `started` is told once the sound has been started; `progress` hears how far the voice has got
    /// — seconds into `samples` at the voice's own pace, not the stretched one — about 30 times a
    /// second while it plays.
    func enqueue(
        _ samples: [Float], sampleRate: Double, lead: TimeInterval,
        started: (@MainActor () -> Void)? = nil,
        progress: (@MainActor (TimeInterval) -> Void)? = nil
    ) async -> Bool {
        guard !Task.isCancelled, !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return true }
        idleStop?.cancel()
        recovery.start()
        if wiredRate != sampleRate {
            // a voice with another sample rate: what is playing finishes before the graph is rewired
            if !pending.isEmpty { _ = await wait(untilRemainingAtMost: 0) }
            guard !Task.isCancelled else { return true }
            wire(format)
        }
        let first = clock.queue(frames: Double(samples.count))
        for buffer in Self.buffers(of: samples, format: format) { schedule(buffer) }
        follower = progress.map { Follower(start: first, frames: Double(samples.count), report: $0) }
        guard startEngine() else {
            failAll()
            return false
        }
        // the ticker is for whoever follows the voice, or returns early
        if progress != nil || lead > 0 { startTicker() }
        started?()
        progress?(0)
        return await wait(untilRemainingAtMost: lead)
    }

    /// Queue `samples` and wait until all of it has been heard.
    func play(_ samples: [Float], sampleRate: Double) async -> Bool {
        await enqueue(samples, sampleRate: sampleRate, lead: 0)
    }

    /// Cut off everything that is queued; whoever is waiting returns.
    func stop() {
        recovery.stop()
        generation += 1
        node.stop()
        forgetQueue()
        let released = waiters
        waiters.removeAll()
        released.forEach { $0.resume(true) }
        scheduleIdleStop()
    }

    // MARK: Plumbing

    private func forgetQueue() {
        pending.removeAll()
        clock.reset()
        follower = nil
    }

    /// Waiting for "all of it" means every piece has been heard; for a lead, that little time is left.
    private func isReady(_ lead: TimeInterval) -> Bool {
        lead > 0 ? remaining <= lead : pending.isEmpty
    }

    private func wait(untilRemainingAtMost lead: TimeInterval) async -> Bool {
        if isReady(lead) { return true }
        return await withCheckedContinuation { continuation in
            nextID += 1
            waiters.append(Waiter(id: nextID, lead: lead, resume: { continuation.resume(returning: $0) }))
        }
    }

    /// Resume whoever has waited long enough.
    private func wake() {
        guard !waiters.isEmpty else { return }
        let ready = waiters.filter { isReady($0.lead) }
        guard !ready.isEmpty else { return }
        waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
        ready.forEach { $0.resume(true) }
    }

    private func failAll() {
        generation += 1
        node.stop()
        forgetQueue()
        let released = waiters
        waiters.removeAll()
        released.forEach { $0.resume(false) }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        nextID += 1
        let piece = Piece(id: nextID, buffer: buffer)
        pending.append(piece)
        hand(piece, to: generation)
    }

    private func hand(_ piece: Piece, to queue: Int) {
        node.scheduleBuffer(piece.buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.heard(piece.id, generation: queue) }
        }
    }

    private func heard(_ id: Int, generation queue: Int) {
        guard queue == generation, let at = pending.firstIndex(where: { $0.id == id }) else { return }
        clock.finishedPiece(frames: Double(pending[at].buffer.frameLength))   // the next piece starts now
        pending.remove(at: at)
        wake()
        if pending.isEmpty {
            // everything queued has been heard: start counting again from nothing
            forgetQueue()
            scheduleIdleStop()
        }
    }

    /// The engine runs on between sentences so they follow each other without a restart; it
    /// stops once nothing has come for a couple of seconds.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.pending.isEmpty, self.waiters.isEmpty else { return }
            self.node.stop()
            self.engine.stop()
        }
    }

    // MARK: Where the voice is

    private func startTicker() {
        guard ticker == nil else { return }
        lastTick = nil
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.pending.isEmpty else { break }
                self.tick()
                // the word timing is fitted to ~105ms, so 15Hz is already finer
                // than the marks can show; a lead-only wait doesn't need that, and
                // Low Power Mode trades it all for wakeups
                let interval: UInt64 = LowPower.on ? 200_000_000
                    : self.follower != nil ? 66_000_000 : 120_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
            self?.ticker = nil
        }
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard engine.isRunning, node.isPlaying, let current = pending.first else { return }
        if let last = lastTick {
            clock.advance(
                seconds: min(max(now.timeIntervalSince(last), 0), 0.2), speed: max(speed, 0.25),
                sampleRate: wiredRate, pieceFrames: Double(current.buffer.frameLength))
        }
        wake()
        if let follower {
            follower.report(clock.seconds(sentenceStart: follower.start, frames: follower.frames, sampleRate: wiredRate))
        }
    }

    /// Connect player → stretch → mixer for this sample rate.
    private func wire(_ format: AVAudioFormat) {
        guard wiredRate != format.sampleRate else { return }
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(stretch)
        engine.connect(node, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        wiredRate = format.sampleRate
    }

    private func startEngine() -> Bool {
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        node.play()
        return true
    }

    /// After an interruption or a route change: queue what has not been heard and carry on.
    private func pickUp() {
        guard recovery.canRecover, !pending.isEmpty else { return }
        generation += 1
        node.stop()
        clock.restartPiece()   // the piece that was playing starts again from its beginning
        let queue = generation
        for piece in pending { hand(piece, to: queue) }
        if !startEngine() { failAll() }
    }

    /// Quarter-second pieces: small enough that a restart repeats little.
    private static func buffers(of samples: [Float], format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let size = max(Int(format.sampleRate / 4), 1)
        return stride(from: 0, to: samples.count, by: size).compactMap { start in
            let count = min(size, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0]
            else { return nil }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            return buffer
        }
    }
}
