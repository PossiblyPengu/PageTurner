import SwiftUI

/// The reader's whole BookMaster shelf — paper books, things read elsewhere, and the ones with a file here.
/// Pageturner's library is the files it reads; BookMaster can hold any book, so a row without a file is
/// normal. A book that is in the library says so and opens; any other shows where it stands on BookMaster,
/// with an optional way to add its file.
struct BookMasterShelfView: View {
    @EnvironmentObject private var library: LibraryStore
    /// Which shelf row is which book in the library — worked out when either changes, not on every redraw.
    @State private var owned: [String: UUID] = [:]

    private var groups: [BMShelf.Group] { BMShelf.groups(BookMaster.shared.shelfRows) }

    private func local(_ row: BMShelfRow) -> Book? {
        owned[row.userBookId].flatMap { id in library.books.first { $0.id == id } }
    }

    private func matchBooks() {
        var found: [String: UUID] = [:]
        for row in BookMaster.shared.shelfRows {
            if let book = library.books.first(where: { BMShelf.match($0, in: [row]) != nil }) { found[row.userBookId] = book.id }
        }
        owned = found
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView(
                    "Nothing on the shelf yet", systemImage: "books.vertical",
                    description: Text("Books you add on BookMaster show up here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        NavigationLink {
                            BookMasterDetailView(pin: row.userBookId)
                        } label: {
                            ShelfRowView(row: row, inLibrary: local(row) != nil)
                        }
                        .onAppear { prefetchCovers(past: row) }
                    }
                }
            }
        }
        .navigationTitle("Your Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await BookMaster.shared.pullShelf(into: library) }
        // again when a book is added, removed, renamed or tied to a row, or the shelf changes
        .task(id: library.books.map { "\($0.id)\($0.title)\($0.author)\($0.bookmasterId ?? "")" }.hashValue
                    ^ BookMaster.shared.shelfRows.hashValue) { matchBooks() }
    }

    /// The jackets ~10 rows further on, warmed before the list is scrolled to them.
    private func prefetchCovers(past row: BMShelfRow) {
        let all = groups.flatMap(\.rows)
        guard let i = all.firstIndex(where: { $0.id == row.id }) else { return }
        prefetchCovers(all.dropFirst(i + 10).prefix(8).map(\.coverURLs))
    }

    /// The first url of each cover chain into `CoverFetch`'s caches.
    private func prefetchCovers(_ chains: [[URL]]) {
        CoverFetch.prefetch(chains.prefix(8).compactMap(\.first))
    }
}

private struct ShelfRowView: View {
    let row: BMShelfRow
    let inLibrary: Bool

    var body: some View {
        HStack(spacing: 12) {
            ShelfCover(row: row).frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                if let author = row.author, !author.isEmpty {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(BMShelf.label(forStatus: row.status))
                    if row.status == "reading", let percent = row.percent { Text("· \(Int(percent.rounded()))%") }
                    if let rating = row.rating, rating > 0 { Text(String(repeating: "★", count: min(rating, 5))) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if inLibrary {
                Label("In library", systemImage: "iphone").labelStyle(.iconOnly).foregroundStyle(Color.ptAccent)
                    .accessibilityLabel("In your library")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ShelfCover: View {
    let row: BMShelfRow

    var body: some View {
        RemoteCover(urls: row.coverURLs, icon: row.isAudio ? "headphones" : "book.closed")
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A shelf book with no file here now lives on the book's detail page —
/// `BookMasterDetailView` shows where it stands and brings the file in.
