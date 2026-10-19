import Foundation
import Observation

/// One audible thing at a time.
///
/// Read-aloud and the audiobook player are separate engines that share one audio
/// session, so nothing stopped them playing over each other. Whichever starts
/// claims focus and the other is paused — not stopped, so it can be resumed. The
/// one that claims also gets the lock-screen buttons (`RemoteControls`).
@MainActor
@Observable
final class AudioFocus {
    static let shared = AudioFocus()

    @ObservationIgnored private var owners: [String: () -> Void] = [:]
    /// Who has the lock-screen buttons: the audiobook or read-aloud, whichever took the stage last and is still
    /// there (a voice sample has no buttons, so never counts). The now-playing strip follows it (`NowPlayingBar`).
    private(set) var holder: String?

    private init() {}

    /// Register something that makes sound, how to quieten it, and (if it has them) what the
    /// lock-screen and headset buttons do while it owns them.
    func register(_ id: String, pause: @escaping () -> Void, remote: RemoteControls.Handlers? = nil) {
        owners[id] = pause
        if let remote { RemoteControls.shared.register(id, remote) }
        holder = RemoteControls.shared.activeOwner
    }

    func unregister(_ id: String) {
        owners[id] = nil
        RemoteControls.shared.unregister(id)
        holder = RemoteControls.shared.activeOwner
    }

    /// `id` is about to make sound: pause everything else, and hand it the buttons.
    func claim(_ id: String) {
        for (other, pause) in owners where other != id { pause() }
        RemoteControls.shared.activate(id)
        holder = RemoteControls.shared.activeOwner
    }

    /// Nothing of ours is open, playing or paused — a brief sound (a voice sample)
    /// may then give the audio session back when it is done.
    var isIdle: Bool { owners.isEmpty }

    /// `id` is the only sound source registered — the session really is its own
    /// to put down (a paused audiobook must not release it while read-aloud is
    /// speaking through it).
    func soleOwner(_ id: String) -> Bool { owners.count == 1 && owners[id] != nil }

    func pauseAll() {
        for pause in owners.values { pause() }
    }
}
