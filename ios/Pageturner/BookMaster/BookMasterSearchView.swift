import SwiftUI

/// BookMaster's own catalogue search — the shelf first, then Open Library —
/// with every hit one tap from your shelf. The Find page of the tab.
struct BookMasterSearchView: View {
    /// A lane carried in from Discover — the field starts filled.
    var starting: String = ""

    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var results: [BMSearchBook] = []
    @State private var searching = false
    @State private var info: String?
    @State private var error: String?
    @State private var busy = false
    @State private var scanning = false
    @State private var offline = false

    var body: some View {
        List {
            if offline, results.isEmpty, !searching, !query.isEmpty {
                ContentUnavailableView(
                    "Couldn’t search", systemImage: "wifi.slash",
                    description: Text("BookMaster didn’t answer. Check the connection and try again."))
                    .listRowBackground(Color.clear)
            } else if results.isEmpty, !searching, !query.isEmpty {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text("Nothing on the shelf or in Open Library by that name."))
                    .listRowBackground(Color.clear)
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty, results.isEmpty {
                Text("Search by title, author or ISBN.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(results.enumerated()), id: \.element.stableKey) { n, hit in
                row(hit)
                    .onAppear { prefetchCovers(past: n) }
            }
            if searching {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let info { Section { Text(info).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Find a book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                    .accessibilityLabel("Scan a barcode")
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                BMScanView { code in
                    query = code
                }
            }
        }
        .searchable(text: $query, prompt: "Title, author or ISBN")
        .task(id: query) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                results = []
                offline = false
                searching = false
                return
            }
            // the pause is part of searching: no "No matches" or stale offline note while it runs
            searching = true
            offline = false
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
        .onAppear {
            if query.isEmpty, !starting.isEmpty {
                query = starting
            }
        }
    }

    /// One hit: the shelf state when it is already yours, or the ways to add it.
    private func row(_ hit: BMSearchBook) -> some View {
        HStack(spacing: 12) {
            RemoteCover(urls: coverURLs(hit))
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let author = hit.author, !author.isEmpty { Text(author) }
                    if let year = hit.year { Text("· \(String(year))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let status = hit.status {
                    Text(BMShelf.label(forStatus: status))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.ptAccent)
                }
            }
            Spacer()
            actions(hit)
        }
    }

    /// Already on the shelf → its page; not → the Add menu.
    @ViewBuilder
    private func actions(_ hit: BMSearchBook) -> some View {
        if let pin = hit.userBookId {
            NavigationLink { BookMasterDetailView(pin: pin) } label: {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        } else {
            Menu {
                ForEach(BMShelfStatus.allCases) { s in
                    Button(s.label) { Task { await add(hit, as: s) } }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.ptAccent)
            }
            .disabled(busy)
        }
    }

    /// The jackets the hit names: its own URL, then Open Library's guesses.
    private func coverURLs(_ hit: BMSearchBook) -> [URL] {
        bmCoverURLs(coverUrl: hit.coverUrl, isbn: hit.isbn, openLibraryId: hit.openLibraryId)
    }

    /// The jackets ~10 hits further on, warmed before the list is scrolled to them.
    private func prefetchCovers(past index: Int) {
        prefetchCovers(results.dropFirst(index + 10).prefix(8).map { coverURLs($0) })
    }

    /// The first url of each cover chain into `CoverFetch`'s caches.
    private func prefetchCovers(_ chains: [[URL]]) {
        CoverFetch.prefetch(chains.prefix(8).compactMap(\.first))
    }

    private func search() async {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { results = []; return }
        searching = true
        let found = await BookMaster.shared.searchCatalogueChecked(title: name, author: "")
        // a newer keystroke cancelled this lookup: leave its state to the next one
        guard !Task.isCancelled, name == query.trimmingCharacters(in: .whitespaces) else { return }
        searching = false
        offline = found == nil
        if let found { results = found }
    }

    /// Shelve a find, annotated with the catalogue facts it carried.
    private func add(_ hit: BMSearchBook, as status: BMShelfStatus) async {
        busy = true
        defer { busy = false }
        do {
            var extra: [String: Any] = [:]
            if let pages = hit.totalPages { extra["total_pages"] = pages }
            if let year = hit.year.flatMap({ Int($0) }) { extra["published_year"] = year }
            if let cover = hit.coverUrl { extra["cover_url"] = cover }
            _ = try await BookMaster.shared.shelve(
                ref: BMBookRef(
                    title: hit.title,
                    author: hit.author ?? "",
                    isbn: hit.isbn,
                    openLibraryId: hit.openLibraryId,
                    userBookId: nil),
                status: status,
                extra: extra)
            info = "“\(hit.title)” is on your \(status.label.lowercased()) shelf."
            error = nil
            await search()
        } catch {
            self.error = error.localizedDescription
            info = nil
        }
    }
}

private extension BMSearchBook {
    /// One result among lookalikes: its catalogue id when it has one.
    var stableKey: String {
        bookId ?? userBookId ?? openLibraryId ?? isbn ?? "\(title)|\(author ?? "")"
    }
}
