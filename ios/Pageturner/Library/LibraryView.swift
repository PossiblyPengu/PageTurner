import SwiftUI
import UniformTypeIdentifiers

/// The library tab: pick up where you left off, then the shelf.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @AppStorage("librarySort") private var sortOrder = LibraryStore.SortOrder.recent.rawValue
    @AppStorage("libraryShelf") private var shelfKey = LibraryView.allKey
    /// One book per line instead of a wall of covers — kept between launches.
    @AppStorage("libraryListView") private var listView = false

    // select mode
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var finding: (done: Int, total: Int)?
    @State private var findResult: String?
    @State private var findTask: Task<Void, Never>?
    /// The books "Find Details" couldn't match, offered by the result alert.
    @State private var findMisses: [UUID] = []
    /// The lookup sheet's fixture, for the simulator screenshot run only.
    @State private var debugLookup: Book?
    /// The misses being walked through one lookup sheet at a time — `reviewBook`
    /// is the one on screen, `reviewPicked` says its sheet ended on a pick (a
    /// pick steps the queue on, a cancel ends the review).
    @State private var reviewQueue: [UUID] = []
    @State private var reviewBook: Book?
    @State private var reviewPicked = false
    /// The folded-in Search tab's field — empty means the shelf shows.
    @State private var query = ""
    @State private var showCatalogs = false
    /// "Later" on the backup reminder, until the view is next built.
    @State private var backupSnoozed = false

    /// Comics and Markdown have no system type everywhere — match them by extension.
    private static let extraTypes = ["cbz", "md", "markdown", "fb2", "fbz"].compactMap { UTType(filenameExtension: $0) }
    /// `.folder`: an audiobook's tracks often come as a folder of parts.
    static let pickerTypes: [UTType] = [.epub, .pdf, .audio, .plainText, .html, .rtf, .zip, .folder] + extraTypes

    /// Built-in shelf filters carry a "~" a shelf name can't start with.
    private static let allKey = "~all"
    private static let upNextKey = "~upnext"
    /// Every series, each under its name with how far through it the reader is and the book that comes next.
    private static let seriesKey = "~series"

    /// The one row of filters: how far along, what kind, then shelves that fill themselves. Each shows only when it
    /// holds some of the library but not all of it. (Status and kind used to be a segmented bar and a picker in the
    /// sort menu besides the chips: three places to look for one thing.)
    private static let smartShelves: [(key: String, label: String, includes: (Book) -> Bool)] = [
        ("~reading", "Reading", { ($0.progression ?? 0) > 0.001 && ($0.progression ?? 0) < 0.995 }),
        ("~unread", "Unread", { ($0.progression ?? 0) <= 0.001 }),
        ("~finished", "Finished", { ($0.progression ?? 0) >= 0.995 }),
        ("~books", "Books", { !$0.isAudio }),
        ("~audio", "Audiobooks", { $0.isAudio }),
    ]

    /// The same, after the series and the reader's own shelves.
    private static let laterShelves: [(key: String, label: String, includes: (Book) -> Bool)] = [
        ("~long", "Long reads", { !$0.isAudio && ($0.pages ?? 0) >= 300 }),
        ("~short", "Short reads", { !$0.isAudio && ($0.pages ?? 0) > 0 && ($0.pages ?? 0) < 150 }),
        ("~month", "Added this month", { $0.addedAt > Date().addingTimeInterval(-30 * 86_400) }),
    ]

    private static var allSmart: [(key: String, label: String, includes: (Book) -> Bool)] { smartShelves + laterShelves }

    private var order: LibraryStore.SortOrder {
        LibraryStore.SortOrder(rawValue: sortOrder) ?? .recent
    }

    private var shelfKeys: [String] {
        let upNext = library.books.contains { $0.bmUpNext == true }
        let series = library.books.contains { $0.series != nil }
        func useful(_ shelves: [(key: String, label: String, includes: (Book) -> Bool)]) -> [String] {
            shelves.filter { shelf in
                let n = library.books.filter(shelf.includes).count
                return n > 0 && n < library.books.count
            }.map(\.key)
        }
        return [Self.allKey] + useful(Self.smartShelves) + (series ? [Self.seriesKey] : []) + (upNext ? [Self.upNextKey] : [])
            + library.shelves + useful(Self.laterShelves)
    }

    /// The chosen shelf, unless it has since been deleted or emptied of its reason to exist.
    private var activeShelfKey: String {
        shelfKeys.contains(shelfKey) ? shelfKey : Self.allKey
    }

    private func shelfLabel(_ key: String) -> String {
        switch key {
        case Self.allKey: return "All"
        case Self.upNextKey: return "Up next"
        case Self.seriesKey: return "Series"
        default: return Self.allSmart.first { $0.key == key }?.label ?? key
        }
    }

    /// How many books a shelf chip stands for — the shelf's own rule, before
    /// the search/status/type filters the grid then applies.
    private func shelfCount(_ key: String) -> Int {
        switch key {
        case Self.allKey: return library.books.count
        case Self.upNextKey: return library.books.filter { $0.bmUpNext == true }.count
        // how many series, not books
        case Self.seriesKey: return Set(library.books.compactMap { $0.series.map(SeriesShelf.key) }).count
        default:
            if let smart = Self.allSmart.first(where: { $0.key == key }) {
                return library.books.filter(smart.includes).count
            }
            return library.books.filter { $0.collections.contains(key) }.count
        }
    }

    /// A live query searches the whole library, like the folded-in tab did —
    /// the shelf and status filters belong to browsing.
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visible: [Book] {
        var list = library.sortedBooks(order: order, query: query)
        guard !searching else { return list }
        // a PDF's text version is reached from the PDF (its cover is badged for it), not a second card on the shelf
        let ids = Set(library.books.map(\.id))
        list = list.filter { book in book.textVersionOf.map { !ids.contains($0) } ?? true }
        switch activeShelfKey {
        case Self.allKey: break
        case Self.upNextKey: list = list.filter { $0.bmUpNext == true }
        case Self.seriesKey: list = list.filter { $0.series != nil }
        default:
            if let smart = Self.allSmart.first(where: { $0.key == activeShelfKey }) {
                list = list.filter(smart.includes)
            } else {
                list = list.filter { $0.collections.contains(activeShelfKey) }
            }
        }
        return list
    }

    /// Missing what a lookup could fill — an author, a blurb, or a jacket on
    /// disk. One pass over the visible books per evaluation, not per cell.
    private func lacksDetails(_ book: Book) -> Bool {
        book.author.isEmpty || book.bookDescription == nil
            || !FileManager.default.fileExists(atPath: library.coverURL(for: book).path)
    }


    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        NavigationStack {
            routing(sheets(
                Group {
                    if library.books.isEmpty {
                        emptyState
                    } else {
                        content
                    }
                }
                .allowsHitTesting(finding == nil)
                .navigationTitle(selecting ? "\(selected.count) Selected" : "Library")
                // the folded-in Search tab: browsing filters step aside for it
                .scrollDismissesKeyboard(.interactively)
                .searchable(text: $query, prompt: "Books and audiobooks")
                .toolbar { toolbar }
                // selecting takes over the bottom edge — the floating tab bar would bleed
                // through the glass capsule under it
                .tabBarChrome(!selecting)
                .safeAreaInset(edge: .bottom) {
                    if selecting { selectionBar }
                }
                .overlay { if let finding { findingCard(finding) } }
            ))
            #if DEBUG
            // CI simulator run: start in select mode with two books ticked, or show the
            // lookup sheet over a fixed set of matches (Debug/DebugScenario.swift)
            .task {
                if UserDefaults.standard.string(forKey: "PTDebugLibraryMode") == "select" {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    selecting = true
                    selected = Set(library.books.prefix(2).map(\.id))
                }
                if UserDefaults.standard.string(forKey: "PTDebugScreen") == "lookup" {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    debugLookup = library.books.first { $0.title == "Moby-Dick" } ?? library.books.first
                }
            }
            #endif
        }
    }

    /// The sheets and the Find Details result — their own function so the
    /// body's modifier chain stays short enough for the type checker.
    private func sheets<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $showCatalogs) { NavigationStack { OPDSCatalogsView() } }
            // the misses "Find Details" couldn't match, one lookup sheet at a time
            #if DEBUG
            // the simulator run's photograph of this sheet: a fixed answer set, no network
            .sheet(item: $debugLookup) { book in
                BookLookupSheet(book: book, initialResults: DebugScenario.lookupCandidates(),
                                onPick: { _, _ in })
            }
            #endif
            .sheet(item: $reviewBook, onDismiss: reviewSheetClosed) { book in
                BookLookupSheet(book: book, modeSwitchable: true,
                    onPick: { candidate, coverOnly in
                        reviewPicked = true
                        applyReview(candidate, to: book.id, coverOnly: coverOnly)
                    },
                    onPickCropped: { image in
                        reviewPicked = true
                        if let jpeg = image.jpegData(compressionQuality: 0.85) {
                            try? jpeg.write(to: library.coverURL(for: book))
                            library.coverChanged()
                        }
                    })
            }
            .alert("Find Details", isPresented: Binding(
                get: { findResult != nil },
                set: { if !$0 { findResult = nil; findMisses = [] } }
            )) {
                if !findMisses.isEmpty {
                    Button("Review \(findMisses.count)") {
                        reviewQueue = findMisses
                        reviewNext()
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(findResult ?? "")
            }
    }

    /// Requests that arrive from outside: a book page's "find this author in
    /// the library" lands here as a shelf search.
    private func routing<V: View>(_ content: V) -> some View {
        content
            // books removed elsewhere (the confirmation lives at the root) drop out of the selection
            // compared by ids, not whole books: every saved page would otherwise compare every book's highlights
            .onChange(of: library.books.map(\.id)) { _, ids in
                selected = selected.intersection(Set(ids))
                if ids.isEmpty { selecting = false }
            }
            .onChange(of: router.librarySearch, initial: true) { _, search in
                guard let search else { return }
                router.librarySearch = nil
                // whatever sheet the tap came from (the book page) is put away first
                router.dismissPresentations()
                router.tab = .library
                query = search
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // one filter + sort per render, not one per use
        let books = visible
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !searching, !selecting, !backupSnoozed, AppPrefs.backupDue(books: library.books.map(\.addedAt)) {
                    BackupReminder {
                        router.showSettings = true
                        AppPrefs.backupSnoozeUntil = Date().addingTimeInterval(2 * 86_400).timeIntervalSince1970
                        backupSnoozed = true
                    } onLater: {
                        AppPrefs.backupSnoozeUntil = Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970
                        backupSnoozed = true
                    }
                }
                if !searching, !selecting { shelfChips }

                if books.isEmpty {
                    if searching {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 40)
                    } else {
                        let filtered = activeShelfKey != Self.allKey
                        ContentUnavailableView {
                            Label(activeShelfKey == "~audio" ? "No Audiobooks" : "No Books",
                                  systemImage: activeShelfKey == "~audio" ? "headphones" : "book.closed")
                        } description: {
                            if filtered {
                                Text("Nothing on this shelf.")
                            } else {
                                Text("Nothing matches yet.")
                            }
                        } actions: {
                            if filtered {
                                Button("Show All Books") { shelfKey = Self.allKey }
                            } else {
                                Button { router.showImporter = true } label: {
                                    Label("Add Books", systemImage: "plus")
                                }
                            }
                        }
                        .padding(.top, 40)
                    }
                } else if activeShelfKey == Self.seriesKey, !searching {
                    ForEach(SeriesShelf.groups(books)) { series in seriesSection(series) }
                } else if order == .series, !searching {
                    // a series together, under its name
                    ForEach(seriesSections(books), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.title3.weight(.semibold))
                            BookGrid(books: section.books, selection: selecting ? $selected : nil, listStyle: listView)
                        }
                    }
                } else {
                    BookGrid(books: books, selection: selecting ? $selected : nil, listStyle: listView)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .ptSoftScrollEdges()
        .refreshable {
            library.refreshMissing()
            await FolderWatcher.shared.scan(library: library)
            if BookMaster.shared.isLinked {
                _ = await BookMaster.shared.pullShelf(into: library)
            }
        }
    }

    /// What a shelf chip's number counts.
    private static func countNoun(_ key: String) -> String { key == seriesKey ? "series" : "books" }

    /// One series: its name, how many of its volumes are read, a way straight into the next, and its books in order.
    private func seriesSection(_ series: SeriesShelf.Series) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.name).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Text(series.finished == series.volumes ? "All \(series.volumes) read" : "\(series.finished) of \(series.volumes) read")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            if let next = series.next, !selecting {
                Button { router.open(next, library: library) } label: {
                    Label {
                        Text("Next: \(next.title)").lineLimit(1)
                    } icon: {
                        Image(systemName: next.isAudio ? "headphones" : "book")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.ptAccent)
                .accessibilityHint(SeriesShelf.place(of: next) ?? "")
            }
            BookGrid(books: series.books, selection: selecting ? $selected : nil, listStyle: listView)
        }
    }

    /// The books, already in series order, cut into one run per series (the rest under "Other books").
    private func seriesSections(_ books: [Book]) -> [(title: String, books: [Book])] {
        var out: [(title: String, books: [Book])] = []
        for book in books {
            let title = book.series ?? "Other books"
            if out.last?.title == title { out[out.count - 1].books.append(book) } else { out.append((title, [book])) }
        }
        return out
    }

    /// "All", "Up next" (books BookMaster has queued) and the reader's own shelves.
    @ViewBuilder
    private var shelfChips: some View {
        if shelfKeys.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelfKeys, id: \.self) { key in
                        let active = key == activeShelfKey
                        Button { shelfKey = key } label: {
                            Text("\(shelfLabel(key)) · \(shelfCount(key))")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(active ? Color.ptAccent : Color(.tertiarySystemFill), in: Capsule())
                                .foregroundStyle(active ? Color.ptOnAccent : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(shelfLabel(key)), \(shelfCount(key)) \(Self.countNoun(key))")
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            // a clipped chip at large text reads as scrollable with a soft edge
            .ptSoftScrollEdges()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            VStack(spacing: 10) {
                Text("Pageturner reads and plays books you already have.")
                Label("Tap + to pick EPUB, PDF, comic, text or audiobook files from Files", systemImage: "plus.circle")
                Label("Or AirDrop, or choose Share → Pageturner from another app", systemImage: "square.and.arrow.down")
                Label("Link BookMaster in Settings to keep your reading in sync", systemImage: "link")
            }
            .font(.footnote)
        } actions: {
            if library.importing {
                ProgressView("Adding books…")
            } else {
                Button { router.showImporter = true } label: {
                    Label("Add Books", systemImage: "plus")
                }
                .ptButtonStyle(prominent: true)
            }
            Button { router.showDrive = true } label: {
                Text("Add from Google Drive")
            }
            Button { showCatalogs = true } label: {
                Text("Browse online catalogs")
            }
            Button { router.showSettings = true } label: {
                Text("Watch a folder in Settings")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                let books = visible
                let all = selected.count == books.count && !books.isEmpty
                let lacking = books.filter(lacksDetails)
                // what the old "Incomplete" filter was for: tick the books missing an author, a blurb or a cover,
                // then Find Details
                Menu {
                    Button(all ? "Deselect All" : "Select All") {
                        selected = all ? [] : Set(books.map(\.id))
                    }
                    if !lacking.isEmpty {
                        Button("Select \(lacking.count) Missing Details") { selected = Set(lacking.map(\.id)) }
                    }
                } label: {
                    Text("Select")
                }
                .accessibilityLabel("Select books")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    selecting = false
                    selected = []
                }
                .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                // sorting and how the shelf is laid out — nothing else (filters are the chips)
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(LibraryStore.SortOrder.allCases) { o in
                            Text(o.label).tag(o.rawValue)
                        }
                    }
                    Divider()
                    Button { listView.toggle() } label: {
                        Label(listView ? "Show as Covers" : "Show as List",
                              systemImage: listView ? "square.grid.2x2" : "list.bullet")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort books")
            }
            if !library.books.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selecting = true } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityLabel("Select books")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { router.showImporter = true } label: { Label("From Files…", systemImage: "folder") }
                    Button { router.showDrive = true } label: { Label("From Google Drive…", systemImage: "externaldrive") }
                    Button { showCatalogs = true } label: { Label("From an Online Catalog…", systemImage: "network") }
                } label: {
                    if library.importing { ProgressView() } else { Image(systemName: "plus") }
                }
                .accessibilityLabel("Add books")
            }
            SettingsToolbarItem(router: router)
        }
    }

    // MARK: Select mode

    private var selectionBar: some View {
        HStack(spacing: 4) {
            barButton("Shelves", "books.vertical") { router.openShelves(Array(selected)) }
            // books waiting in Google Drive come down one after another, in the background
            if selected.contains(where: { library.inCloud.contains($0) }) {
                barButton("Download", "icloud.and.arrow.down") {
                    for book in library.books where selected.contains(book.id) && library.inCloud.contains(book.id) {
                        DriveDownloads.shared.start(book, library: library)
                    }
                    selecting = false
                    selected = []
                }
            }
            barButton("Find Details", "sparkle.magnifyingglass") { findDetails() }
            barButton("Remove", "trash") {
                router.askDelete(library.books.filter { selected.contains($0.id) })
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .ptGlassCapsule()
        .padding(.bottom, 6)
        // the floating chat button would sit on the rightmost action while this is up
        .hidesChatButton()
        .disabled(selected.isEmpty || finding != nil)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(minWidth: 84, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Look each ticked book up online and fill in what it's missing. The ones
    /// no match agreed with are offered afterwards, one at a time ("Review").
    private func findDetails() {
        let ids = Array(selected)
        guard !ids.isEmpty else { return }
        finding = (0, ids.count)
        findTask = Task {
            var updated = 0
            var misses: [UUID] = []
            for (n, id) in ids.enumerated() {
                if Task.isCancelled { break }
                if await MetadataLookup.autoApply(to: id, library: library) {
                    updated += 1
                } else if stillMissing(id) {
                    misses.append(id)
                }
                finding = (n + 1, ids.count)
            }
            let stopped = Task.isCancelled
            finding = nil
            findTask = nil
            findMisses = stopped ? [] : misses
            findResult = stopped
                ? (updated == 0 ? nil : "Stopped. Updated \(updated) of \(ids.count) book\(ids.count == 1 ? "" : "s").")
                : misses.isEmpty
                ? (updated == 0
                    ? "No new details turned up for \(ids.count == 1 ? "that book" : "those books")."
                    : "Updated \(updated) of \(ids.count) book\(ids.count == 1 ? "" : "s").")
                : "Updated \(updated) of \(ids.count) — \(misses.count) got no match."
        }
    }

    /// Still short of what a lookup could have filled — an author, or a jacket
    /// on disk. The cheap check, for sorting a "no match" into worth reviewing.
    private func stillMissing(_ id: UUID) -> Bool {
        guard let book = library.books.first(where: { $0.id == id }) else { return false }
        return book.author.isEmpty
            || !FileManager.default.fileExists(atPath: library.coverURL(for: book).path)
    }

    /// Open the lookup sheet on the queue's first book, skipping any gone meanwhile.
    private func reviewNext() {
        while let id = reviewQueue.first {
            reviewQueue.removeFirst()
            if let book = library.books.first(where: { $0.id == id }) {
                reviewBook = book
                return
            }
        }
        reviewBook = nil
    }

    /// The lookup sheet closed: a pick steps to the next missed book, a cancel
    /// ends the review.
    private func reviewSheetClosed() {
        if reviewPicked {
            reviewPicked = false
            reviewNext()
        } else {
            reviewQueue = []
        }
    }

    /// The reviewer picked a match for a missed book: fill what it is still
    /// missing the way `MetadataLookup.autoApply` does — then its jacket, when
    /// there is none. `coverOnly` (the sheet's switch) takes the jacket alone.
    private func applyReview(_ candidate: MetadataCandidate, to id: UUID, coverOnly: Bool) {
        guard let book = library.books.first(where: { $0.id == id }) else { return }
        if !coverOnly {
            library.mutate(id) { MetadataLookup.fillMissing(&$0, from: candidate) }
            if let pin = candidate.bookmasterId, book.bookmasterId == nil {
                library.updateBookMaster(id) { $0.bookmasterId = pin }
            }
        }
        // the jacket is fetched off the pick — the callback itself stays synchronous
        if !candidate.coverURLs.isEmpty,
           !FileManager.default.fileExists(atPath: library.coverURL(for: book).path) {
            Task { await MetadataLookup.applyCover(from: candidate.coverURLs, to: book, library: library) }
        }
    }

    private func findingCard(_ progress: (done: Int, total: Int)) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(.ptAccent)
            Text("Finding details… \(progress.done) of \(progress.total)")
                .font(.subheadline)
            Button("Cancel") { findTask?.cancel() }
                .font(.subheadline)
        }
        .padding(20)
        .frame(maxWidth: 280)
        .ptGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity)
    }
}

