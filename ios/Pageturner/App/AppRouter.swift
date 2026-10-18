import Foundation
import Observation

enum AppTab: Hashable {
    /// `books` is the BookMaster shelf, `together` the other reader, `stats`
    /// the numbers — BookMaster's one dashboard grew into three tabs.
    case reading, library, books, together, stats
}

/// BookMaster has a book further on than this device — asked before it opens.
struct ResumePrompt: Identifiable {
    let id = UUID()
    let book: Book
    /// BookMaster's place, 0…1.
    let fraction: Double
}

/// What is on screen above the tabs: the book sheets and settings — and which
/// tab is up, since the Reading tab is itself the reader and the player. One
/// place decides, so a book opened from the library, search or a sheet goes to
/// the same destination.
@Observable
@MainActor
final class AppRouter {
    /// The selected tab. Opening a book lands on Reading, where the book is.
    var tab: AppTab = .library
    /// The book open in the Reading tab — nil when the tab shows its browse list.
    var reading: Book?
    var detail: Book?
    var editing: Book?
    var showSettings = false
    var showImporter = false
    /// BookMaster's sign-in sheet (the Together and Stats prompts open it directly).
    var showLink = false
    /// Books waiting on "Remove from Library?" — removing deletes their files.
    var pendingDelete: [Book] = []
    var shelfTarget: ShelfTarget?
    var resumePrompt: ResumePrompt?
    /// Where the Together tab should go next — the chat, or a page of one of the web apps — set by
    /// a tapped notification and cleared by the tab once it has gone there.
    var suiteTarget: BMDeepLink.Target?

    /// Close whatever sheet is up, so a request from outside lands on screen.
    func dismissPresentations() {
        detail = nil
        editing = nil
        shelfTarget = nil
        showSettings = false
        showLink = false
        showImporter = false
        resumePrompt = nil
    }

    func openShelves(_ ids: [UUID]) { shelfTarget = ShelfTarget(bookIDs: ids) }

    func askDelete(_ books: [Book]) { pendingDelete = books }

    /// Open a book: an audiobook goes to the player (and keeps playing when it
    /// is left); anything else opens in the reader. Either way the Reading tab
    /// is where the book is. When BookMaster has the book further on than this
    /// device, that is asked about first.
    func open(_ book: Book, library: LibraryStore) {
        if library.missing.contains(book.id) {
            library.lastError = "“\(book.title)” can’t be opened: its file is no longer on this device (it may have been deleted in the Files app). Remove it from the library to clear it."
            return
        }
        if AppPrefs.resumeAsk, let fraction = ResumeOffer.target(for: book) {
            resumePrompt = ResumePrompt(book: book, fraction: fraction)
            return
        }
        launch(book, library: library)
    }

    /// The answer to the resume prompt: jump to BookMaster's place or stay put —
    /// either way the book then opens.
    func answer(_ prompt: ResumePrompt, jump: Bool, library: LibraryStore) {
        resumePrompt = nil
        library.answerResume(prompt.book.id, fraction: jump ? prompt.fraction : nil)
        launch(library.books.first { $0.id == prompt.book.id } ?? prompt.book, library: library)
    }

    /// Leaving an open book: back to the library, with the position kept so the
    /// Reading tab's list can offer it again.
    func leaveReading() {
        reading = nil
        tab = .library
    }

    private func launch(_ book: Book, library: LibraryStore) {
        if book.isAudio {
            // an ebook still open in the Reading tab would cover the player: close it (its view saves the place)
            reading = nil
            PlaybackCoordinator.shared.start(book, library: library)
        } else {
            reading = book
        }
        tab = .reading
    }
}
