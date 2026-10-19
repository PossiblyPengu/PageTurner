import SwiftUI
import UniformTypeIdentifiers

/// The library tab: pick up where you left off, then the shelf.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @AppStorage("libraryFilter") private var filter: Filter = .all
    @AppStorage("libraryStatus") private var status: Status = .any
    @AppStorage("librarySort") private var sortOrder = LibraryStore.SortOrder.recent.rawValue
    @AppStorage("libraryShelf") private var shelfKey = LibraryView.allKey

    // select mode
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var finding: (done: Int, total: Int)?
    @State private var findResult: String?
    @State private var findTask: Task<Void, Never>?
    /// The folded-in Search tab's field — empty means the shelf shows.
    @State private var query = ""
    @State private var showDuplicates = false
    @State private var showCatalogs = false
    @State private var showHighlights = false
    /// "Later" on the backup reminder, until the view is next built.
    @State private var backupSnoozed = false

    /// Comics and Markdown have no system type everywhere — match them by extension.
    private static let extraTypes = ["cbz", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    /// `.folder`: an audiobook's tracks often come as a folder of parts.
    static let pickerTypes: [UTType] = [.epub, .pdf, .audio, .plainText, .html, .zip, .folder] + extraTypes

    /// Built-in shelf filters carry a "~" a shelf name can't start with.
    private static let allKey = "~all"
    private static let upNextKey = "~upnext"

    /// Shelves that fill themselves from what the books are. Each shows only when it holds some of the
    /// library but not all of it.
    private static let smartShelves: [(key: String, label: String, includes: (Book) -> Bool)] = [
        ("~unread", "Unread", { ($0.progression ?? 0) <= 0.001 }),
        ("~long", "Long reads", { !$0.isAudio && ($0.pages ?? 0) >= 300 }),
        ("~short", "Short reads", { !$0.isAudio && ($0.pages ?? 0) > 0 && ($0.pages ?? 0) < 150 }),
        ("~month", "Added this month", { $0.addedAt > Date().addingTimeInterval(-30 * 86_400) }),
    ]

    /// How far along a book is: none of it, some of it, all of it.
    enum Status: String, CaseIterable, Identifiable {
        case any = "Any Status", inProgress = "In Progress", unread = "Unread", finished = "Finished"
        var id: String { rawValue }

        func includes(_ book: Book) -> Bool {
            let p = book.progression ?? 0
            switch self {
            case .any: return true
            case .inProgress: return p > 0.001 && p < 0.995
            case .unread: return p <= 0.001
            case .finished: return p >= 0.995
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", books = "Books", audiobooks = "Audiobooks"
        var id: String { rawValue }
    }

    private var order: LibraryStore.SortOrder {
        LibraryStore.SortOrder(rawValue: sortOrder) ?? .recent
    }

    private var shelfKeys: [String] {
        let upNext = library.books.contains { $0.bmUpNext == true }
        let smart = Self.smartShelves.filter { shelf in
            let n = library.books.filter(shelf.includes).count
            return n > 0 && n < library.books.count
        }.map(\.key)
        return [Self.allKey] + (upNext ? [Self.upNextKey] : []) + library.shelves + smart
    }

    /// The chosen shelf, unless it has since been deleted or emptied of its reason to exist.
    private var activeShelfKey: String {
        shelfKeys.contains(shelfKey) ? shelfKey : Self.allKey
    }

    private func shelfLabel(_ key: String) -> String {
        switch key {
        case Self.allKey: return "All"
        case Self.upNextKey: return "Up next"
        default: return Self.smartShelves.first { $0.key == key }?.label ?? key
        }
    }

    /// A live query searches the whole library, like the folded-in tab did —
    /// the shelf and status filters belong to browsing.
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visible: [Book] {
        var list = library.sortedBooks(order: order, query: query)
        guard !searching else { return list }
        switch activeShelfKey {
        case Self.allKey: break
        case Self.upNextKey: list = list.filter { $0.bmUpNext == true }
        default:
            if let smart = Self.smartShelves.first(where: { $0.key == activeShelfKey }) {
                list = list.filter(smart.includes)
            } else {
                list = list.filter { $0.collections.contains(activeShelfKey) }
            }
        }
        if status != .any { list = list.filter { status.includes($0) } }
        switch filter {
        case .all: return list
        case .books: return list.filter { !$0.isAudio }
        case .audiobooks: return list.filter { $0.isAudio }
        }
    }


    var body: some View {
        NavigationStack {
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
            .searchable(text: $query, prompt: "Books and audiobooks")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .overlay { if let finding { findingCard(finding) } }
            .sheet(isPresented: $showDuplicates) { DuplicatesSheet() }
            .sheet(isPresented: $showHighlights) { HighlightsHubView() }
            .sheet(isPresented: $showCatalogs) { NavigationStack { OPDSCatalogsView() } }
            .alert("Find Details", isPresented: Binding(
                get: { findResult != nil },
                set: { if !$0 { findResult = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(findResult ?? "")
            }
            // books removed elsewhere (the confirmation lives at the root) drop out of the selection
            .onChange(of: library.books) { _, books in
                selected = selected.intersection(Set(books.map(\.id)))
                if books.isEmpty { selecting = false }
            }
            #if DEBUG
            // CI simulator run: start in select mode with two books ticked (Debug/DebugScenario.swift)
            .task {
                guard UserDefaults.standard.string(forKey: "PTDebugLibraryMode") == "select" else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                selecting = true
                selected = Set(library.books.prefix(2).map(\.id))
            }
            #endif
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
                if !searching {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if !selecting { shelfChips }
                }

                if books.isEmpty {
                    if searching {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 40)
                    } else {
                        let shelved = activeShelfKey != Self.allKey
                        let filtered = status != .any || filter != .all || shelved
                        ContentUnavailableView {
                            Label(filter == .audiobooks ? "No Audiobooks" : "No Books",
                                  systemImage: filter == .audiobooks ? "headphones" : "book.closed")
                        } description: {
                            if filtered {
                                Text("The current shelf and filters are hiding everything.")
                            } else {
                                Text("Nothing matches yet.")
                            }
                        } actions: {
                            if filtered {
                                Button("Show All Books") { status = .any; filter = .all; shelfKey = Self.allKey }
                            } else {
                                Button { router.showImporter = true } label: {
                                    Label("Add Books", systemImage: "plus")
                                }
                            }
                        }
                        .padding(.top, 40)
                    }
                } else if order == .series, !searching {
                    // a series together, under its name
                    ForEach(seriesSections(books), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.title3.weight(.semibold))
                            BookGrid(books: section.books, selection: selecting ? $selected : nil)
                        }
                    }
                } else {
                    BookGrid(books: books, selection: selecting ? $selected : nil)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .ptSoftScrollEdges()
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
                            Text(shelfLabel(key))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(active ? Color.ptAccent : Color(.tertiarySystemFill), in: Capsule())
                                .foregroundStyle(active ? Color.ptOnAccent : Color.primary)
                        }
                        .buttonStyle(.plain)
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
                Button(all ? "Deselect All" : "Select All") {
                    selected = all ? [] : Set(books.map(\.id))
                }
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
                Menu {
                    Section("Sort") {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(LibraryStore.SortOrder.allCases) { o in
                                Text(o.label).tag(o.rawValue)
                            }
                        }
                    }
                    Section("Show") {
                        Picker("Status", selection: $status) {
                            ForEach(Status.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Section("Notes") {
                        Button { showHighlights = true } label: {
                            Label("All Highlights", systemImage: "highlighter")
                        }
                    }
                    Section("Get books") {
                        Button { showCatalogs = true } label: {
                            Label("Online Catalogs…", systemImage: "network")
                        }
                    }
                    Section("Tidy") {
                        Button { showDuplicates = true } label: {
                            Label("Find Duplicates…", systemImage: "square.on.square")
                        }
                    }
                } label: {
                    Image(systemName: status == .any ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel(status == .any ? "Sort books" : "Sort and filter books, showing \(status.rawValue)")
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
                } label: {
                    if library.importing { ProgressView() } else { Image(systemName: "plus") }
                }
                .accessibilityLabel("Add books")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    // MARK: Select mode

    private var selectionBar: some View {
        HStack(spacing: 4) {
            barButton("Shelves", "books.vertical") { router.openShelves(Array(selected)) }
            barButton("Find Details", "sparkle.magnifyingglass") { findDetails() }
            barButton("Remove", "trash") {
                router.askDelete(library.books.filter { selected.contains($0.id) })
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .ptGlassCapsule()
        .padding(.bottom, 6)
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

    /// Look each ticked book up online and fill in what it's missing.
    private func findDetails() {
        let ids = Array(selected)
        guard !ids.isEmpty else { return }
        finding = (0, ids.count)
        findTask = Task {
            var updated = 0
            for (n, id) in ids.enumerated() {
                if Task.isCancelled { break }
                if await MetadataLookup.autoApply(to: id, library: library) { updated += 1 }
                finding = (n + 1, ids.count)
            }
            let stopped = Task.isCancelled
            finding = nil
            findTask = nil
            findResult = stopped
                ? (updated == 0 ? nil : "Stopped. Updated \(updated) of \(ids.count) book\(ids.count == 1 ? "" : "s").")
                : updated == 0
                ? "No new details turned up for \(ids.count == 1 ? "that book" : "those books")."
                : "Updated \(updated) of \(ids.count) book\(ids.count == 1 ? "" : "s")."
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity)
    }
}

