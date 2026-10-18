import AVFoundation
import UIKit

/// Keeping Pageturner running in the background, so it can tell the reader the moment something arrives.
///
/// A sideloaded app has no push, and iOS suspends an app that is not in front within seconds — except one
/// that is playing audio. So, when the reader has asked for it, Pageturner plays a silent sound on a loop
/// while it is in the background, and uses the time to ask BookMaster what is new every half minute
/// (`BMKeepAlive` holds the rules); anything new is posted as a notification with Pageturner's own icon.
///
/// What it costs: battery, and iOS can still end the app after some hours (a memory squeeze, a restart):
/// opening Pageturner again starts it over. It mixes with other sound, never takes the audio session
/// from a book being played, and goes as soon as Pageturner is in front again.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var looking: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        // a call or an alarm stops the sound; when it ends, the loop goes on
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, self.player != nil,
                      raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
                else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player?.play()
            }
        }
    }

    /// Whether it is running now.
    var isRunning: Bool { player != nil }

    /// The app went to the background or came back (or the switch changed): start or stop as the rules say.
    func update(background: Bool) {
        let run = BMKeepAlive.shouldRun(
            enabled: AppPrefs.stayConnected && Notifier.shared.enabled,
            linked: BookMaster.shared.isLinked,
            background: background)
        if run { start() } else { stop() }
    }

    private func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // a book being played has set the session up already: leave its category alone, so its lock-screen
        // controls stay; otherwise mix with whatever else is playing
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        guard let player = try? AVAudioPlayer(data: BMKeepAlive.silence(), fileTypeHint: AVFileType.wav.rawValue) else { return }
        player.numberOfLoops = -1
        player.prepareToPlay()
        guard player.play() else { return }
        self.player = player
        Log.event("keepalive", "started")
        looking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BMKeepAlive.pollInterval(lowPower: LowPower.on)))
                guard !Task.isCancelled else { return }
                await Notifier.shared.refresh(notify: true)
                self?.restartIfStopped()
            }
        }
    }

    /// iOS can stop the sound without saying (another app took the session): start it again.
    private func restartIfStopped() {
        guard let player, !player.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func stop() {
        guard player != nil else { return }
        looking?.cancel()
        looking = nil
        player?.stop()
        player = nil
        Log.event("keepalive", "stopped")
        // give the session back to whatever else was playing, unless a book of ours still holds it
        if AudioFocus.shared.isIdle {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
