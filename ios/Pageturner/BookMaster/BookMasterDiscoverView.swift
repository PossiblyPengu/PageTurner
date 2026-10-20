import SwiftUI

/// What to read next, the way BookMaster works it out: the books the other
/// reader finished and liked that are not on your shelf, and the lanes your
/// own shelf earns — each one a tap to put the book on yours.
struct BookMasterDiscoverView: View {
    @State private var recs: BMRecommendations?
    @State private var error: String?
    @State private var info: String?
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        List {
            if let recs {
                if !recs.partnerPicks.isEmpty { picksSection(recs) }
                lanesSection(recs)
            }
            if loading, recs == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let recs, recs.partnerPicks.isEmpty, recs.authors.isEmpty, recs.subjects.isEmpty {
                ContentUnavailableView(
                    "No suggestions yet", systemImage: "sparkles",
                    description: Text("BookMaster learns the lanes from what you and the other reader finish."))
                    .listRowBackground(Color.clear)
            }
            if let info { Section { Text(info).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .ptSoftScrollEdges()
        .navigationTitle("What to read next")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    /// Books they finished and liked that you have not got — each with an Add.
    private func picksSection(_ recs: BMRecommendations) -> some View {
        Section("From \(recs.partner?.name ?? "the other reader")’s shelf") {
            ForEach(recs.partnerPicks, id: \.title) { pick in
                HStack(spacing: 12) {
                    RemoteCover(urls: bmCoverURLs(coverUrl: pick.coverUrl, isbn: pick.isbn, openLibraryId: pick.openLibraryId))
                    .frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pick.title ?? "Untitled").font(.body.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            if let author = pick.author, !author.isEmpty { Text(author) }
                            if let rating = pick.rating, rating > 0 {
                                Text("· " + String(repeating: "★", count: min(rating, 5)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await add(pick) } } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.ptAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel("Add to want to read")
                }
            }
        }
    }

    /// The lanes your own shelf earns — the authors you return to and the
    /// subjects that keep coming up, each a tap into BookMaster's search.
    private func lanesSection(_ recs: BMRecommendations) -> some View {
        Section("Your lanes") {
            if recs.authors.isEmpty, recs.subjects.isEmpty {
                Text("No lanes yet — finish a few books and they appear.")
                    .foregroundStyle(.secondary)
            }
            ForEach(recs.authors, id: \.self) { name in
                NavigationLink { BookMasterSearchView(starting: name) } label: {
                    Label(name, systemImage: "person")
                }
            }
            ForEach(recs.subjects, id: \.self) { name in
                NavigationLink { BookMasterSearchView(starting: name) } label: {
                    Label(name, systemImage: "tag")
                }
            }
        }
    }

    /// Put a partner pick on the want-to-read shelf, by its catalogue ids.
    private func add(_ pick: BMPartnerPick) async {
        busy = true
        defer { busy = false }
        do {
            var extra: [String: Any] = [:]
            if let pages = pick.totalPages { extra["total_pages"] = pages }
            if let year = pick.publishedYear { extra["published_year"] = year }
            if let cover = pick.coverUrl { extra["cover_url"] = cover }
            _ = try await BookMaster.shared.shelve(
                ref: BMBookRef(
                    title: pick.title ?? "",
                    author: pick.author ?? "",
                    isbn: pick.isbn,
                    openLibraryId: pick.openLibraryId,
                    userBookId: nil),
                status: .wantToRead,
                extra: extra)
            info = "“\(pick.title ?? "It")” is on your want-to-read shelf."
            error = nil
        } catch {
            self.error = error.localizedDescription
            info = nil
        }
    }

    private func load() async {
        guard BookMaster.shared.isLinked else {
            recs = nil
            loading = false
            return
        }
        do {
            let fetched = try await BookMaster.shared.fetchRecommendations()
            recs = fetched
            error = nil
            // the row of jackets just under the fold is warmed before it is scrolled to
            CoverFetch.prefetch(fetched.partnerPicks.prefix(8).compactMap {
                bmCoverURLs(coverUrl: $0.coverUrl, isbn: $0.isbn, openLibraryId: $0.openLibraryId).first
            })
        } catch {
            if recs == nil { self.error = error.localizedDescription }
        }
        loading = false
    }
}
