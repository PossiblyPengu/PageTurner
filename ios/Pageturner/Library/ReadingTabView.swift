import SwiftUI

/// The Reading tab is the reading itself: the open book, or the player for
/// the audiobook on the go — not a card that opens a second screen. Leaving
/// either just switches back to the library (`AppRouter.leaveReading`).
/// Only when nothing is open does it show the "what you are in" list.
struct ReadingTabView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    private let playback = PlaybackCoordinator.shared

    var body: some View {
        if let book = router.reading {
            ReaderView(book: book, library: library) { router.leaveReading(library: library) }
                // a different book needs a new reader, not a reused one
                .id(book.id)
        } else if let player = playback.player {
            NowPlayingView(player: player, onStop: { playback.stop() }) { router.leaveReading(library: library) }
        } else {
            ReadingNowView(onBrowse: { router.tab = .library })
        }
    }
}
