import AVFoundation
import MediaPlayer
import UIKit

/// The volume buttons as page turns (Reading sheet → "Volume buttons turn pages"): down is the next page, up the
/// one before, or the other way round.
///
/// iOS says nothing about the buttons themselves, only that the volume changed: the session's `outputVolume` is
/// watched, a change is a press, and the volume is put back where it was through a volume view kept off screen —
/// whose being in the window is also what keeps iOS's volume banner away. Only while nothing of ours is playing
/// (`mayTurn`, asked at every press): a voice or an audiobook makes the buttons volume again at once. With nothing
/// of ours holding the session, this one mixes with whatever else is playing, so it stops no one's music; with a
/// paused voice or audiobook holding it, its category is theirs and is left alone.
@MainActor
final class VolumeButtonPager {
    /// Whether a press may turn the page now.
    var mayTurn: () -> Bool = { false }
    /// A press that turns the page: `down` for the volume-down button.
    var onTurn: ((_ down: Bool) -> Void)?

    private let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }()
    private var observation: NSKeyValueObservation?
    /// The volume being put back: the change that brings it there is not a press.
    private var restoring: Float?
    /// This turned the session on, so it may turn it off.
    private var ownsSession = false

    var isListening: Bool { observation != nil }

    /// Listen, with the off-screen volume view in `host` (the reader's view).
    func start(in host: UIView) {
        if volumeView.superview !== host { host.addSubview(volumeView) }
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        if AudioFocus.shared.isIdle {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            ownsSession = true
        }
        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue else { return }
            Task { @MainActor in self?.changed(from: old, to: new) }
        }
        // at either end a press that way changes nothing and so says nothing: a step in from it, once the
        // volume view has its slider
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.isListening else { return }
            let volume = session.outputVolume
            if volume > 0.99 {
                self.set(1 - Self.step)
            } else if volume < 0.01 {
                self.set(Self.step)
            }
        }
        Log.event("reader", "volume buttons turn pages")
    }

    func stop() {
        volumeView.removeFromSuperview()
        guard observation != nil else { return }
        observation?.invalidate()
        observation = nil
        restoring = nil
        // the session goes back only if it was this one's to begin with and is no one else's now (the keep-alive
        // takes it as the app leaves)
        if ownsSession, AudioFocus.shared.isIdle, !BackgroundKeepAlive.shared.isRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        ownsSession = false
    }

    /// One press of a volume button moves the volume a sixteenth.
    private static let step: Float = 1.0 / 16

    private func changed(from old: Float, to new: Float) {
        guard isListening else { return }
        if let restoring, abs(new - restoring) < 0.01 {
            self.restoring = nil
            return
        }
        guard abs(new - old) > 0.001, mayTurn() else { return }
        onTurn?(new < old)
        set(old)
    }

    private func set(_ volume: Float) {
        guard let slider = volumeView.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        restoring = volume
        slider.setValue(volume, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
