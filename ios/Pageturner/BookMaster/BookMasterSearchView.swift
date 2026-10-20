import SwiftUI

/// Finding a book to shelve: the same catalogues BookMaster's own page asks —
/// Open Library and Apple Books, queried straight from here — with every hit
/// one tap from your shelf. A hit that is already shelved is pinned from the
/// shelf copy the app keeps, so applying it can never push a duplicate.
/// The Find page of the tab.
struct BookMasterSearchView: View {
    /// A lane carried in from Discover — the field starts filled.
    var starting: String = ""

    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var results: [CatalogueHit] = []
    @State private var searching = false
    @State private var info: String?
    @State private var correctedTo: String?
    @State private var error: String?
    @State private var busy = false
    @State private var scanning = false
    @State private var offline = false

    var body: some View {
        List {
            if offline, results.isEmpty, !searching, !query.isEmpty {
                ContentUnavailableView(
                    "Couldn’t search", systemImage: "wifi.slash",
                    description: Text("The catalogues didn’t answer. Check the connection and try again."))
                    .listRowBackground(Color.clear)
            } else if results.isEmpty, !searching, !query.isEmpty {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text("Nothing in Open Library or Apple Books by that name."))
                    .listRowBackground(Color.clear)
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty, results.isEmpty {
                Text("Search by title, author or ISBN.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let correctedTo {
                Text("Showing results for “\(correctedTo)”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(results, id: \.key) { hit in
                row(hit)
                    .onAppear { prefetchCovers(past: hit.key) }
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
                correctedTo = nil
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
    private func row(_ hit: CatalogueHit) -> some View {
        HStack(spacing: 12) {
            RemoteCover(urls: hit.coverURLs)
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if !hit.author.isEmpty, hit.author != "Unknown" { Text(hit.author) }
                    if let year = hit.publishedYear { Text("· \(String(year))") }
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
    private func actions(_ hit: CatalogueHit) -> some View {
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

    /// The jackets ~10 hits further on, warmed before the list is scrolled to them.
    private func prefetchCovers(past key: String) {
        guard let index = results.firstIndex(where: { $0.key == key }) else { return }
        prefetchCovers(results.dropFirst(index + 10).prefix(8).map(\.coverURLs))
    }

    /// The first url of each cover chain into `CoverFetch`'s caches.
    private func prefetchCovers(_ chains: [[URL]]) {
        CoverFetch.prefetch(chains.prefix(8).compactMap(\.first))
    }

    @MainActor
    private func search() async {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { results = []; return }
        searching = true
        let reply = await CatalogueSearch.search(name, limit: 24)
        // a newer keystroke cancelled this lookup: leave its state to the next one
        guard !Task.isCancelled, name == query.trimmingCharacters(in: .whitespaces) else { return }
        searching = false
        offline = reply.failed
        var books = reply.books
        CatalogueSearch.pin(&books, to: BookMaster.shared.shelfRows)
        results = books
        correctedTo = reply.correctedTo
    }

    /// Shelve a find, annotated with the catalogue facts it carried.
    @MainActor
    private func add(_ hit: CatalogueHit, as status: BMShelfStatus) async {
        busy = true
        defer { busy = false }
        do {
            var extra: [String: Any] = [:]
            if let cover = hit.coverUrl { extra["cover_url"] = cover }
            _ = try await BookMaster.shared.shelve(
                ref: BMBookRef(
                    title: hit.title,
                    author: hit.author == "Unknown" ? "" : hit.author,
                    isbn: hit.isbn,
                    openLibraryId: hit.openLibraryId.isEmpty ? nil : hit.openLibraryId,
                    userBookId: nil,
                    bookDescription: hit.summary,
                    publishedYear: hit.publishedYear,
                    totalPages: hit.totalPages),
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
