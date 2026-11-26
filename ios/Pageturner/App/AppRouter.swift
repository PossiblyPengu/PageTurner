import Foundation
import Observation

enum AppTab: Hashable {
    /// `bookmaster` holds BookMaster's own pages — the shelf, the other reader, the numbers — behind one switch
    /// (`AppRouter.bmPage`). They had grown into three tabs of their own.
    case reading, library, bookmaster
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
    /// The Google Drive browser, for adding books from the Drive.
    var showDrive = false
    /// BookMaster's sign-in sheet (the Together and Stats prompts open it directly).
    var showLink = false
    /// Books waiting on "Remove from Library?" — removing deletes their files.
    var pendingDelete: [Book] = []
    var shelfTarget: ShelfTarget?
    var resumePrompt: ResumePrompt?
    /// A book just finished: the sheet that asks for a rating and what to do with its file (`FinishedBookSheet`).
    var finished: Book?
    /// One of the web apps, full screen over the tabs: where a tapped notification, or a link out of a BookMaster
    /// page into Kindred or Quest Log, leads.
    var browser: BMWebLaunch?
    /// The chat as a full page over whatever is up — what the floating chat button opens.
    var showChat = false
    /// Set to have the library shelf filter to this text (a book page's author tap); the shelf clears it once read.
    var librarySearch: String?
    /// The screens that cover the floating button's place (the chat itself, the in-app browser), by
    /// identity, so one that appears twice still counts once.
    private(set) var chatButtonHiders: Set<UUID> = []

    /// An ebook is open in the Reading tab and that tab is up: the reader, where nothing floats.
    var readerOpen: Bool { tab == .reading && reading != nil }

    /// Which of BookMaster's pages its tab shows.
    var bmPage: BMWebTab = .shelf

    /// The BookMaster tab, at `page`.
    func showBookMaster(_ page: BMWebTab) {
        bmPage = page
        tab = .bookmaster
    }

    func hideChatButton(_ id: UUID, _ hide: Bool) {
        if hide { chatButtonHiders.insert(id) } else { chatButtonHiders.remove(id) }
    }

    /// Close whatever sheet is up, so a request from outside lands on screen.
    /// Something is up over the tabs that a book opening by itself would close (an edit, Settings, the chat…).
    var presenting: Bool {
        detail != nil || editing != nil || shelfTarget != nil || showSettings || showLink || showImporter || showDrive
            || showChat || browser != nil || resumePrompt != nil || finished != nil
    }

    /// A book has just been finished (the reader left at its end, an audiobook played out, Mark as Finished): ask
    /// once for a rating and what to do with its file. Not when it isn't finished, was asked already, or there is
    /// nothing to ask (no BookMaster to rate for, no file left). A sheet that is up (the book's page, after Mark as
    /// Finished there) is let go first — two at once can't be shown.
    func offerFinished(_ id: UUID, library: LibraryStore) {
        guard let book = library.books.first(where: { $0.id == id }) else { return }
        let share = book.progression ?? 0
        guard share >= 0.995 else {
            Log.event("finished", "not asked about “\(book.title)”: it stands at \(Int((share * 100).rounded()))%")
            return
        }
        guard !FinishedAsk.asked(id), FinishedBookSheet.worthAsking(book, library: library) else {
            Log.event("finished", "not asked about “\(book.title)” again: asked once for this finish")
            return
        }
        FinishedAsk.mark(id)
        // never at once: a sheet asked for while a menu or another sheet is still going away is refused by iOS without
        // a word — the request was lost, and the `finished` left set kept every later one waiting behind it
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            var waited = 0
            // something up (the book's page after Mark as Finished there, the settings): after it, for up to a minute
            while self.presenting, waited < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            if waited > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            guard !self.presenting, let latest = library.books.first(where: { $0.id == id }) else {
                // still covered: the book can be asked about another time
                FinishedAsk.forget(id)
                Log.event("finished", "not asked about “\(book.title)”: something else stayed up")
                return
            }
            Log.event("finished", "asking about “\(latest.title)”")
            #if DEBUG
            NSLog("PTFinishedAsked %@", latest.title)   // the simulator run's check (85, 86)
            #endif
            self.finished = latest
        }
    }

    func dismissPresentations() {
        detail = nil
        editing = nil
        shelfTarget = nil
        showSettings = false
        showLink = false
        showImporter = false
        showDrive = false
        showChat = false
        browser = nil
        resumePrompt = nil
        finished = nil
    }

    /// Go where a notification leads — from its banner, or from the list. It is read by then.
    func open(_ item: BMInboxItem) {
        BMInboxStore.shared.markRead(ids: [item.id])
        switch BMInbox.destination(for: item) {
        case .chat:
            // already in front: closing and opening it again would lose the draft and the place
            if showChat { Notifier.shared.noteChatOpened(); return }
            openSuite(.chat, covered: presenting)
        case .together:
            dismissPresentations()
            showBookMaster(.together)
        case let .web(app, url):
            openSuite(.web(app, url), covered: presenting)
        }
    }

    /// Open the chat or one of the web apps. Whatever is up (the settings, say) is put away first; what is asked
    /// for follows once it is gone. `covered`: something was up when the request came, so it is waited for.
    func openSuite(_ target: BMDeepLink.Target, covered: Bool) {
        guard BookMaster.shared.isLinked else { return }
        dismissPresentations()
        if covered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.present(target) }
        } else {
            present(target)
        }
    }

    private func present(_ target: BMDeepLink.Target) {
        switch target {
        case .chat:
            Notifier.shared.noteChatOpened()
            showChat = true
        case let .web(app, url) where app == .bookmaster:
            // BookMaster's pages are the BookMaster tab's: the page they belong to, there — not a second copy full screen
            let tab = BMWebNav.tab(for: url, otherwise: bmPage)
            showBookMaster(tab)
            BMWebPages.shared.tab(tab).open(BMWebNav.embedded(url))
        case let .web(app, url):
            browser = BMWebLaunch(app: app, url: url)
        }
    }

    func openShelves(_ ids: [UUID]) { shelfTarget = ShelfTarget(bookIDs: ids) }

    func askDelete(_ books: [Book]) { pendingDelete = books }

    /// Open a book: an audiobook goes to the player (and keeps playing when it
    /// is left); anything else opens in the reader. Either way the Reading tab
    /// is where the book is. When BookMaster has the book further on than this
    /// device, that is asked about first.
    func open(_ book: Book, library: LibraryStore) {
        // a book still in the Drive has nothing to open: its page is where it is downloaded
        if library.inCloud.contains(book.id) {
            OpenAt.cancel(for: book.id)
            detail = book
            return
        }
        if library.missing.contains(book.id) {
            OpenAt.cancel(for: book.id)
            library.lastError = "“\(book.title)” can’t be opened: its file is no longer on this device (it may have been deleted in the Files app). Remove it from the library to clear it."
            return
        }
        if AppPrefs.resumeAsk, !OpenAt.isPending(for: book.id), let fraction = ResumeOffer.target(for: book) {
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

    /// Play an audiobook that is still in the Drive straight from there, without downloading it.
    func stream(_ book: Book, library: LibraryStore) {
        guard book.isAudio else { return }
        detail = nil
        launch(book, library: library)
    }

    /// Give back the space of a Drive book's files (the book stays in the library): what is playing, read to or open
    /// from them is put away first.
    func removeDownload(_ book: Book, library: LibraryStore) {
        if PlaybackCoordinator.shared.bookID == book.id { PlaybackCoordinator.shared.stop() }
        ReadAloudHost.shared.stop(bookID: book.id)
        if reading?.id == book.id { reading = nil }
        library.removeDownload(book.id)
    }

    /// A book is about to leave the library (removed, or merged into another copy): what is playing, read aloud
    /// or open from it is put away first.
    func putAway(_ id: UUID) {
        if PlaybackCoordinator.shared.bookID == id { PlaybackCoordinator.shared.stop() }
        ReadAloudHost.shared.stop(bookID: id)
        if reading?.id == id { reading = nil }
        if detail?.id == id { detail = nil }
        if editing?.id == id { editing = nil }
    }

    /// "Mark as Finished" — records it and tells BookMaster; when the "clear files of
    /// finished books" setting is on, the files go too.
    func markFinished(_ book: Book, library: LibraryStore) {
        library.markFinished(book.id)
        if AppPrefs.autoClearFinished { clearFinished(book, library: library) }
        offerFinished(book.id, library: library)
    }

    /// Clear a finished book's files: a Drive copy goes back to the Drive (the book stays),
    /// any other finished book leaves the library with it. What is playing, read to or open
    /// from them is put away first.
    func clearFinished(_ book: Book, library: LibraryStore) {
        if PlaybackCoordinator.shared.bookID == book.id { PlaybackCoordinator.shared.stop() }
        ReadAloudHost.shared.stop(bookID: book.id)
        if reading?.id == book.id { reading = nil }
        if detail?.id == book.id { detail = nil }
        if editing?.id == book.id { editing = nil }
        library.clearFinishedFiles(book)
    }

    /// The settings sweep: every finished book's files cleared. `kept` stayed in the library
    /// (Drive copies), `removed` left it, `freed` is the space given back.
    @discardableResult
    func clearFinishedBooks(library: LibraryStore) -> (kept: Int, removed: Int, freed: Int64) {
        var kept = 0, removed = 0, freed: Int64 = 0
        for target in library.clearableFinished() {
            freed += target.bytes
            if target.book.drive != nil { kept += 1 } else { removed += 1 }
            clearFinished(target.book, library: library)
        }
        return (kept, removed, freed)
    }

    /// The now-playing strip for a book being read aloud was tapped: the book, at the place the voice has reached.
    func openNarration() {
        guard let book = ReadAloudHost.shared.held?.book else { return }
        reading = book
        tab = .reading
    }

    /// Leaving an open book: back to the library, with the position kept so the
    /// Reading tab's list can offer it again. A book that was finished behind the
    /// reader or player frees its files here, when the setting is on — never out
    /// from under audio still playing (a re-listen).
    func leaveReading(library: LibraryStore) {
        let playback = PlaybackCoordinator.shared
        // the library's record, not the copy the reader was opened with: that still has the place it was opened at, so
        // a book finished in this sitting never counted as finished here
        let leaving = (reading ?? playback.bookID.flatMap { id in library.books.first { $0.id == id } })
            .flatMap { left in library.books.first { $0.id == left.id } }
        reading = nil
        tab = .library
        if AppPrefs.autoClearFinished, let book = leaving,
           (book.progression ?? 0) >= 0.995, playback.player?.isPlaying != true {
            clearFinished(book, library: library)
        }
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
