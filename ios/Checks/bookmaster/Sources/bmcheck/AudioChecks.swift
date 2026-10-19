import Foundation

@MainActor
final class RemoteControls {
    static let shared = RemoteControls()
    struct Handlers {}
    private var registered: Set<String> = []
    private(set) var activeOwner: String?
    func register(_ id: String, _ handlers: Handlers) { registered.insert(id) }
    func activate(_ id: String) { if registered.contains(id) { activeOwner = id } }
    func unregister(_ id: String) { registered.remove(id); if activeOwner == id { activeOwner = nil } }
}

@MainActor
func runAudioChecks() async {
    section("Audio ownership and asynchronous startup")
    let focus = AudioFocus.shared
    var preview = true, audiobook = true
    focus.register("preview", pause: { preview = false; focus.unregister("preview") })
    focus.register("audiobook", pause: { audiobook = false }, remote: .init())
    focus.claim("preview")
    check("voice preview pauses audiobook", !audiobook && preview)
    audiobook = true
    focus.claim("audiobook")
    check("audiobook silences preview", audiobook && !preview)
    focus.unregister("audiobook")
    focus.register("readaloud", pause: {}, remote: .init())
    focus.claim("readaloud")
    focus.unregister("readaloud")
    focus.register("readaloud", pause: {}, remote: .init())
    focus.claim("readaloud")
    check("restarted narration regains focus and remotes", !focus.isIdle && RemoteControls.shared.activeOwner == "readaloud")
    focus.unregister("readaloud")

    section("Now-playing strip")
    check("nothing loaded: no strip", NowPlayingBar.choose(audiobook: false, narration: false, holder: nil) == nil)
    check("an audiobook alone is the audiobook strip", NowPlayingBar.choose(audiobook: true, narration: false, holder: nil) == .audiobook)
    check("narration alone is the narration strip, whoever held the buttons last",
          NowPlayingBar.choose(audiobook: false, narration: true, holder: "audiobook") == .narration)
    check("both loaded: the one that took the stage last", NowPlayingBar.choose(audiobook: true, narration: true, holder: "readaloud") == .narration
          && NowPlayingBar.choose(audiobook: true, narration: true, holder: "audiobook") == .audiobook)
    check("both loaded and nobody claimed: the audiobook", NowPlayingBar.choose(audiobook: true, narration: true, holder: nil) == .audiobook)
    check("a chapter title leads the line", NowPlayingBar.subtitle(chapter: "  Chapter 3 ", author: "Herbert") == "Chapter 3")
    check("no chapter: the author", NowPlayingBar.subtitle(chapter: nil, author: "Herbert") == "Herbert"
          && NowPlayingBar.subtitle(chapter: "  ", author: "Herbert") == "Herbert")
    check("neither: no line", NowPlayingBar.subtitle(chapter: nil, author: " ") == nil)

    focus.register("audiobook", pause: {}, remote: .init())
    focus.register("readaloud", pause: {}, remote: .init())
    focus.claim("readaloud")
    check("the stage's holder is whoever claimed it", focus.holder == "readaloud")
    focus.claim("audiobook")
    check("and changes hands with the claim", focus.holder == "audiobook")
    focus.register("preview", pause: {})
    focus.claim("preview")
    check("a voice sample has no buttons, so never holds the stage", focus.holder == "audiobook")
    focus.unregister("preview")
    focus.unregister("readaloud")
    focus.unregister("audiobook")
    check("nothing registered, nothing held", focus.isIdle && focus.holder == nil)

    let startup = AudioStartup()
    var waiting: CheckedContinuation<Int, Never>?
    var plays: [Int] = []
    startup.start(locate: { await withCheckedContinuation { waiting = $0 } }, play: { plays.append($0) })
    while waiting == nil { await Task.yield() }
    startup.cancel()
    waiting?.resume(returning: 1)
    for _ in 0..<10 { await Task.yield() }
    check("dismissal cancels pending narration", plays.isEmpty)
    waiting = nil
    startup.start(locate: { await withCheckedContinuation { waiting = $0 } }, play: { plays.append($0) })
    while waiting == nil { await Task.yield() }
    startup.start(locate: { 3 }, play: { plays.append($0) })
    waiting?.resume(returning: 2)
    for _ in 0..<10 { await Task.yield() }
    check("only the newest startup speaks", plays == [3])
    startup.cancel()

    section("Neural interruption and explicit progress actions")
    var recovery = AudioRecovery()
    recovery.beginInterruption()
    check("configuration change cannot resume during interruption", !recovery.canRecover)
    recovery.endInterruption(shouldResume: false)
    check("interruption without permission stays paused", !recovery.canRecover)
    recovery.start()
    check("explicit play can resume", recovery.canRecover)
    recovery.beginInterruption()
    recovery.endInterruption(shouldResume: true)
    check("permitted interruption can recover", recovery.canRecover)
    recovery.stop()
    check("stop or headphone removal blocks graph recovery", !recovery.canRecover)
    var checkpoint = PlaybackProgress()
    checkpoint.saved(position: 50, progression: 0.5)
    check("own saves do not trigger external adoption", !checkpoint.adopt(position: 50, progression: 0.5, playhead: 50))
    check("restart is an external progress change", checkpoint.adopt(position: nil, progression: 0, playhead: 50))
    check("restarted playhead can be saved", checkpoint.maySave(at: 0))
    checkpoint.saved(position: 50, progression: 0.5)
    _ = checkpoint.adopt(position: 50, progression: 1, playhead: 51)
    check("finish survives pause and close without new listening", !checkpoint.maySave(at: 51))
    check("further listening can update progress", checkpoint.maySave(at: 52))
}
