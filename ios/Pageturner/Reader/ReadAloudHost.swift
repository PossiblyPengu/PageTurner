import Foundation
import Observation

/// Keeps a book being read aloud going after its reader is left.
///
/// Read-aloud is the reader's: the voice follows the navigator that holds the book. Leaving the reader for another
/// tab or the library used to stop it; now the reader (`ReaderModel`, with the book open in it) is handed here
/// while narration is under way, and the now-playing strip above the tab bar controls it from there. Tapping the
/// strip opens the book again, taking the same reader back (`take`) — the page catches up to where the voice is.
///
/// One book at a time. Only a reader that is *not* on screen is held: while it is up, its own controls are the
/// controls, and `held` is nil.
@MainActor
@Observable
final class ReadAloudHost {
    static let shared = ReadAloudHost()

    /// The reader whose book is being read aloud with nobody looking at it.
    private(set) var held: ReaderModel?
    /// The reader in front, if any (not retained: its view owns it).
    @ObservationIgnored private weak var shown: ReaderModel?

    private init() {}

    /// A reader is on screen now. Whatever was held for another book is let go — one voice, and the book in
    /// front is the one being opened — and the book's own narration gets its page back.
    func show(_ model: ReaderModel) {
        if let other = held, other !== model { other.stopReadAloud() }
        held = nil
        shown = model
        model.readerShown()
    }

    /// A reader is being left. Narration under way is kept (the reader with it), anything else stops with it.
    func leave(_ model: ReaderModel) {
        if shown === model { shown = nil }
        guard let readAloud = model.readAloud, readAloud.isActive else {
            model.stopReadAloud()
            return
        }
        if let other = held, other !== model { other.stopReadAloud() }
        model.readerHidden()
        held = model
    }

    /// A reader for `book` is being made: the one held for it, if narration kept it going.
    func take(for book: Book) -> ReaderModel? {
        guard let model = held, model.book.id == book.id else { return nil }
        held = nil
        return model
    }

    /// The narration of a reader ended by itself (the book's end, the sleep timer, failures) or was stopped.
    func narrationEnded(_ model: ReaderModel) {
        guard held === model else { return }
        held = nil
        model.readerLetGo()
    }

    /// Stop the narration of a book (being deleted), held or in front, or of whatever is held.
    func stop(bookID: UUID? = nil) {
        for model in [held, shown] {
            if let model, bookID == nil || model.book.id == bookID { model.stopReadAloud() }   // → narrationEnded
        }
    }
}
