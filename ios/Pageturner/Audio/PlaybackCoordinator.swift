import Foundation
import Observation

/// Owns the one audiobook that is playing, so it keeps playing when the
/// player is left and the mini player can show it anywhere. The Reading tab
/// is where the player lives — there is no separate player screen.
@Observable
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    private(set) var player: AudioPlayer?
    private(set) var bookID: UUID?

    var isActive: Bool { player != nil }

    private init() {}

    /// Open a book's audio. Choosing the book that is already loaded just
    /// points the Reading tab back at it instead of restarting it.
    func start(_ book: Book, library: LibraryStore) {
        if bookID == book.id, let player {
            // a restart or a jump to BookMaster's place may have changed the record since it loaded
            player.adopt(library.books.first { $0.id == book.id } ?? book)
            // open already, and asked to go where the ebook was
            if let place = AudioStartAt.take(for: book.id) { player.go(to: place) }
            return
        }
        stop()
        let next = AudioPlayer(book: book, library: library)
        player = next
        bookID = book.id
        Task { await next.open() }
    }

    /// Stop playback, save the position and drop the player.
    func stop() {
        player?.close()
        player = nil
        bookID = nil
    }
}
