import SwiftUI

/// The app's frame: tabs, the mini player docked above them, and everything
/// that presents over the tabs. On iOS 26 the tab bar and its mini player are
/// Liquid Glass and the bar shrinks as you scroll; before that it is a plain
/// tab bar with the mini player above it.
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("app-appearance") private var appAppearance = "system"
    @AppStorage("bm-badge") private var bmBadge = true
    @State private var router = AppRouter()
    private let playback = PlaybackCoordinator.shared
    private let speech = ReadAloudHost.shared
    private let downloads = DriveDownloads.shared
    private let focus = AudioFocus.shared
    private let bookMaster = BookMaster.shared
    private let notifier = Notifier.shared
    private let inbox = BMInboxStore.shared
    private let intents = IntentRouter.shared

    /// The app-wide scheme: "system" leaves it to iOS.
    private var scheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        routing(alerts(bookSheets(shell.overlay { chatButton }.overlay(alignment: .top) { BMBannerHost() })))
            .tint(.ptAccent)
            // the reader sets its own scheme inside; this is the preference for the rest
            .preferredColorScheme(scheme)
            // outermost, so the tabs and everything presented over them can read it
            .environment(router)
    }

    /// Requests that arrive from outside: a tapped suggestion notification, Siri,
    /// Shortcuts, a Spotlight result.
    private func routing<V: View>(_ content: V) -> some View {
        content
            .onChange(of: notifier.openTogether, initial: true) { _, open in
                guard open else { return }
                router.dismissPresentations()
                router.tab = .together
                notifier.openTogether = false
            }
            .onChange(of: notifier.tappedItemID, initial: true) { _, id in
                guard let id else { return }
                notifier.tappedItemID = nil
                openNotification(id)
            }
            // however the link ended (a button, or three refusals), its leftovers go: pins, Up next, banners
            .onChange(of: bookMaster.isLinked) { old, linked in
                guard old, !linked else { return }
                library.clearBookMasterFields()
                notifier.reset()
                BMQuestLogChat.shared.reset()
            }
            .onChange(of: intents.request, initial: true) { _, request in
                guard let request else { return }
                intents.request = nil
                handle(request)
            }
            #if DEBUG
            // CI simulator run: launch arguments choose a screen (Debug/DebugScenario.swift)
            .task { await DebugScenario.run(library: library, router: router) { router.tab = $0 } }
            #endif
    }

    /// A tapped notification leads where its inbox item does; a pile ("3 new things") or one the inbox no longer
    /// holds leads to the Together tab.
    private func openNotification(_ id: String) {
        let inbox = BMInboxStore.shared
        inbox.loadIfNeeded()
        if let item = inbox.items.first(where: { $0.id == id }) {
            router.open(item)
        } else {
            router.dismissPresentations()
            router.tab = .together
        }
    }

    private func handle(_ request: IntentRouter.Request) {
        if case let .openDownloaded(id) = request {
            // a book being read is never swapped out for one that has just come down
            guard !router.readerOpen, let book = library.books.first(where: { $0.id == id }) else { return }
            router.dismissPresentations()
            router.open(book, library: library)
            return
        }
        router.dismissPresentations()
        switch request {
        case let .open(id):
            // a book that is gone still answers with its shelf, not with nothing
            router.tab = .library
            guard let book = library.books.first(where: { $0.id == id }) else { return }
            router.open(book, library: library)
        case let .finish(id):
            router.tab = .library
            if let book = library.books.first(where: { $0.id == id }) {
                router.markFinished(book, library: library)
            }
        case let .restart(id):
            router.tab = .library
            library.restart(id)
        case .continueReading:
            // with nothing in progress the request still lands where one starts
            router.tab = .reading
            guard let book = library.continueBook else { return }
            router.open(book, library: library)
        case let .openSuite(target):
            // the Together tab opens it: it owns the chat and the in-app browser
            router.tab = .together
            router.suiteTarget = target
        case .importBooks:
            router.tab = .library
            router.showImporter = true
        case .openDownloaded:
            break   // handled above
        }
    }

    // MARK: Presentations

    /// A book's detail, its edit form, shelves and Settings.
    private func bookSheets<V: View>(_ content: V) -> some View {
        @Bindable var r = router
        return content
            .sheet(item: $r.detail) { book in detailSheet(book) }
            .sheet(item: $r.editing) { book in editSheet(book) }
            .sheet(item: $r.shelfTarget) { ShelvesSheet(target: $0) }
            .sheet(isPresented: $r.showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $r.showChat) { BMChatScreen() }
            .sheet(isPresented: $r.showLink) { linkSheet }
            .sheet(isPresented: $r.showDrive) { DriveBrowserView(purpose: .importBooks) }
            .fileImporter(
                isPresented: $r.showImporter,
                allowedContentTypes: LibraryView.pickerTypes,
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    Task { await library.importFiles(urls) }
                }
            }
    }

    /// BookMaster's sign-in; the code it ends with is spent here and the shelf pulled.
    private var linkSheet: some View {
        BookMasterLinkSheet(
            onCode: { code in
                router.showLink = false
                Task {
                    if let message = await BookMasterLinker.shared.finish(code: code) {
                        bookMaster.notice = "Couldn’t link BookMaster: \(message)"
                    } else {
                        await bookMaster.pullShelf(into: library)
                        await bookMaster.pushCovers(from: library)
                        await bookMaster.beat()
                    }
                }
            },
            onCancel: { router.showLink = false })
    }

    private func detailSheet(_ shown: Book) -> some View {
        // what the library holds now: a download that finished has given the book its real title and cover
        let book = library.books.first { $0.id == shown.id } ?? shown
        let cloud = downloads.badge(for: book.id, inCloud: library.inCloud.contains(book.id))
        return BookDetailSheet(
            book: book, cover: library.cover(for: book),
            onOpen: {
                router.detail = nil
                // "Read again" starts from the beginning, not the last page
                if (book.progression ?? 0) >= 0.995 { library.restart(book.id) }
                router.open(library.books.first { $0.id == book.id } ?? book, library: library)
            },
            onEdit: {
                router.detail = nil
                // present the edit sheet after this one is fully dismissed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.editing = book }
            },
            onDelete: {
                router.detail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.askDelete([book]) }
            },
            onShelves: {
                router.detail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.openShelves([book.id]) }
            },
            onFinish: {
                router.markFinished(book, library: library)
                router.detail = nil
            },
            onRestart: {
                library.restart(book.id)
                router.detail = nil
            },
            onRate: { stars in
                library.rate(book.id, stars: stars)
            },
            cloud: cloud,
            downloadState: downloads.states[book.id],
            onDownload: { downloads.start(book, library: library, open: true) },
            onCancelDownload: { downloads.cancel(book.id) },
            onStream: book.isAudio ? { router.stream(book, library: library) } : nil,
            onRemoveDownload: {
                router.detail = nil
                router.removeDownload(book, library: library)
            },
            onClearFile: {
                router.detail = nil
                router.clearFinished(book, library: library)
            },
            onShelfMove: { status in
                bookMaster.moveToShelf(status, bookID: book.id, library: library)
            },
            onLookup: { await MetadataLookup.enrichDriveBooks([book.id], library: library) },
            onTextVersion: book.ext == "pdf" ? { openTextVersion(of: book) } : nil)
    }

    /// A PDF's text version, made the first time, then opened in the reader like any book.
    private func openTextVersion(of pdf: Book) {
        Task {
            do {
                let text = try await library.makeTextVersion(of: pdf)
                router.detail = nil
                // the sheet goes first, so the reader isn't opened under it
                try? await Task.sleep(nanoseconds: 350_000_000)
                router.open(text, library: library)
            } catch is CancellationError {
                return
            } catch {
                library.lastError = error.localizedDescription
            }
        }
    }

    private func editSheet(_ book: Book) -> some View {
        BookEditSheet(book: book) { updated in
            library.update(updated)
            // a lookup that named a BookMaster shelf row pins the book to it
            if let pin = updated.bookmasterId, pin != book.bookmasterId {
                library.updateBookMaster(book.id) { $0.bookmasterId = pin }
            }
            router.editing = nil
        }
    }

    /// BookMaster's notice, the "continue from BookMaster?" question and the remove confirmation.
    private func alerts<V: View>(_ content: V) -> some View {
        content
            // imports can start from any tab, so their failures are reported here
            .alert("Import problem", isPresented: Binding(
                get: { library.lastError != nil },
                set: { if !$0 { library.lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.lastError ?? "")
            }
            .alert("BookMaster", isPresented: noticeShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bookMaster.notice ?? "")
            }
            .alert(
                "Continue from BookMaster?",
                isPresented: resumeShown,
                presenting: router.resumePrompt
            ) { prompt in
                Button("Go to \(ResumeOffer.label(prompt.fraction))") {
                    router.answer(prompt, jump: true, library: library)
                }
                Button("Stay at \(ResumeOffer.label(prompt.book.progression ?? 0))") {
                    router.answer(prompt, jump: false, library: library)
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(Self.resumeMessage(prompt))
            }
            .confirmationDialog(
                Self.deleteTitle(router.pendingDelete),
                isPresented: deleteShown,
                titleVisibility: .visible,
                presenting: router.pendingDelete.isEmpty ? nil : router.pendingDelete
            ) { books in
                Button(books.count == 1 ? "Remove from Library" : "Remove \(books.count) Books", role: .destructive) {
                    for book in books {
                        if playback.bookID == book.id { playback.stop() }
                        ReadAloudHost.shared.stop(bookID: book.id)
                        if router.reading?.id == book.id { router.reading = nil }
                        if router.detail?.id == book.id { router.detail = nil }
                        if router.editing?.id == book.id { router.editing = nil }
                        library.delete(book)
                    }
                }
            } message: { _ in
                Text("This also deletes the file from this device. Your BookMaster shelf isn’t touched.")
            }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { bookMaster.notice != nil }, set: { if !$0 { bookMaster.notice = nil } })
    }

    private var resumeShown: Binding<Bool> {
        Binding(get: { router.resumePrompt != nil }, set: { if !$0 { router.resumePrompt = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { !router.pendingDelete.isEmpty }, set: { if !$0 { router.pendingDelete = [] } })
    }

    private static func resumeMessage(_ prompt: ResumePrompt) -> String {
        let remote = ResumeOffer.label(prompt.fraction)
        let here = ResumeOffer.label(prompt.book.progression ?? 0)
        return "BookMaster has you \(remote) of the way through “\(prompt.book.title)”. This device is at \(here)."
    }

    private static func deleteTitle(_ books: [Book]) -> String {
        books.count == 1 ? "Remove “\(books[0].title)”?" : "Remove \(books.count) books?"
    }

    // MARK: Shells

    @ViewBuilder
    private var shell: some View {
        // the bottom accessory can be switched off from iOS 26.1
        if #available(iOS 26.1, *) {
            modernShell
        } else {
            classicShell
        }
    }

    @available(iOS 26.1, *)
    private var modernShell: some View {
        @Bindable var r = router
        return TabView(selection: $r.tab) {
            Tab("Reading", systemImage: "book", value: AppTab.reading) {
                ReadingTabView()
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView()
            }
            Tab("Books", systemImage: "bookmark.fill", value: AppTab.books) {
                BookMasterBooksView()
            }
            Tab("Together", systemImage: "person.2.fill", value: AppTab.together) {
                BookMasterTogetherView()
            }
            .badge(bmBadge ? inbox.unreadCount : 0)
            Tab("Stats", systemImage: "chart.bar.fill", value: AppTab.stats) {
                BookMasterStatsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: showMiniPlayer) { miniPlayer }
    }

    private var classicShell: some View {
        @Bindable var r = router
        return TabView(selection: $r.tab) {
            withMiniPlayer(ReadingTabView())
                .tabItem { Label("Reading", systemImage: "book") }
                .tag(AppTab.reading)
            withMiniPlayer(LibraryView())
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            withMiniPlayer(BookMasterBooksView())
                .tabItem { Label("Books", systemImage: "bookmark.fill") }
                .tag(AppTab.books)
            withMiniPlayer(BookMasterTogetherView())
                .tabItem { Label("Together", systemImage: "person.2.fill") }
                .badge(bmBadge ? inbox.unreadCount : 0)
                .tag(AppTab.together)
            withMiniPlayer(BookMasterStatsView())
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(AppTab.stats)
        }
    }

    // MARK: Pieces

    /// The chat button that floats over every tab but the reader. The tab bar — and the mini player
    /// above it, when one is up — is room it keeps clear.
    private var chatButton: some View {
        BMChatButtonLayer(bottomReserve: showMiniPlayer ? 128 : 64)
    }

    /// The strip that is docked: the audiobook in the player, or a book being read aloud whose reader was left
    /// (`ReadAloudHost`) — whichever took the stage last when both are there. The audiobook's steps aside while its
    /// full player fills the Reading tab; reading an ebook with audio going keeps it, as the way back.
    private var nowPlaying: NowPlayingBar? {
        NowPlayingBar.choose(
            audiobook: playback.player != nil && !(router.tab == .reading && router.reading == nil),
            narration: speech.held?.readAloud != nil,
            holder: focus.holder)
    }

    private var showMiniPlayer: Bool { nowPlaying != nil }

    @ViewBuilder
    private var miniPlayer: some View {
        switch nowPlaying {
        case .audiobook:
            if let player = playback.player {
                MiniPlayer(player: player) { router.reading = nil; router.tab = .reading }
            }
        case .narration:
            if let held = speech.held, let readAloud = held.readAloud {
                NarrationMiniPlayer(
                    model: held, readAloud: readAloud, cover: library.coverThumbnail(for: held.book, maxPixels: 120)
                ) { router.openNarration() }
            }
        case nil:
            EmptyView()
        }
    }

    /// Before iOS 26 there is no bottom accessory, so the strip rides
    /// above the tab bar as an inset of each tab — a floating capsule,
    /// the same silhouette the accessory has.
    private func withMiniPlayer<V: View>(_ content: V) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 6) {
            if showMiniPlayer {
                miniPlayer
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .ptGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 12)
            }
        }
    }

}

