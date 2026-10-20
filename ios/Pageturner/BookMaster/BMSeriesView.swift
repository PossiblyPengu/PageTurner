import SwiftUI

/// Named runs — the web's Series page. Each runs down how many are owned and
/// read; one opens to its books, where a shelved book joins or leaves the run.
struct BMSeriesView: View {
    @State private var series: [BMSeries]?
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var actionError: String?

    var body: some View {
        List {
            if let series {
                if series.isEmpty {
                    ContentUnavailableView(
                        "No series yet", systemImage: "books.vertical",
                        description: Text("File books into a run — a trilogy, a universe, an author's order — and it counts them here."))
                    .listRowBackground(Color.clear)
                }
                ForEach(series) { run in
                    NavigationLink { BMSeriesDetailView(id: run.id, name: run.name) } label: {
                        row(run)
                    }
                }
            } else if let error {
                ContentUnavailableView(
                    "BookMaster can't be reached", systemImage: "wifi.exclamationmark",
                    description: Text(error))
                .listRowBackground(Color.clear)
            } else {
                ProgressView("Asking BookMaster…").frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .ptSoftScrollEdges()
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { naming = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New series")
            }
        }
        .alert("New series", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Series live on the catalogue — every reader who owns the books sees the run.")
        }
        .alert("Couldn’t do that", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ run: BMSeries) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.name).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let author = run.author, !author.isEmpty { Text(author) }
                if let owned = run.booksOwned, let read = run.booksRead {
                    Text("· \(read) of \(owned) read")
                }
                if let total = run.totalBooks, total > 0 {
                    Text("· \(total) in the run")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard BookMaster.shared.isLinked else {
            series = []
            error = "Link BookMaster to see your series."
            return
        }
        do {
            series = try await BookMaster.shared.fetchSeries()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        do {
            _ = try await BookMaster.shared.createSeries(name: name)
            await load()
        } catch {
            newName = name
            actionError = error.localizedDescription
        }
    }
}

/// One run's books in order — the caller's shelf state rides along, so a book
/// can be filed in (from your shelf) or taken out (a swipe).
struct BMSeriesDetailView: View {
    let id: String
    var name: String = ""

    @State private var detail: BMSeriesDetail?
    @State private var error: String?
    @State private var adding = false
    @State private var busy = false
    @State private var actionError: String?
    @State private var pickError: String?

    var body: some View {
        List {
            if let detail {
                ForEach(Array(detail.books.enumerated()), id: \.element.id) { index, book in
                    bookRow(book, position: book.position ?? index + 1)
                        .swipeActions {
                            Button("Remove from series", role: .destructive) {
                                Task { await unfile(book) }
                            }
                        }
                }
            } else if let error {
                ContentUnavailableView(
                    "BookMaster can't be reached", systemImage: "wifi.exclamationmark",
                    description: Text(error))
                .listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .ptSoftScrollEdges()
        .navigationTitle(detail?.series?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("File a book into the series")
                    .disabled(busy)
            }
        }
        .sheet(isPresented: $adding) { pickSheet }
        .alert("Couldn’t do that", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func bookRow(_ book: BMSeriesBook, position: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title ?? "Untitled").font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let author = book.author, !author.isEmpty { Text(author) }
                    if let year = book.publishedYear { Text("· \(String(year))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let status = book.status {
                Text(BMShelf.label(forStatus: status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ptAccent)
            } else {
                Text("not shelved").font(.caption2).foregroundStyle(.tertiary)
            }
            if let pin = book.userBookId {
                NavigationLink { BookMasterDetailView(pin: pin) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Open \(book.title ?? "book") on your shelf")
            }
        }
    }

    /// The books on the caller's shelf not already in the run — filing one
    /// puts it at the end.
    private var pickSheet: some View {
        NavigationStack {
            List(candidates) { row in
                Button { Task { await file(row) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.medium)).lineLimit(2)
                            if let author = row.author {
                                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "plus.circle").foregroundStyle(Color.ptAccent)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing to file", systemImage: "checkmark.circle",
                        description: Text("Every book on your shelf is already in this run."))
                }
            }
            .navigationTitle("File into \(name.isEmpty ? "series" : name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { adding = false }
                }
            }
        }
        .alert("Couldn’t add it", isPresented: Binding(
            get: { pickError != nil }, set: { if !$0 { pickError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickError ?? "")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var candidates: [BMShelfRow] {
        // The run knows a shelved book two ways: the caller's pin on it, and
        // the catalogue id when another reader's copy is what was filed.
        let pins = Set((detail?.books ?? []).compactMap(\.userBookId))
        let bookIds = Set((detail?.books ?? []).map(\.id))
        return BookMaster.shared.shelfRows.filter {
            !pins.contains($0.userBookId) && !bookIds.contains($0.bookId)
        }
    }

    private func file(_ row: BMShelfRow) async {
        busy = true
        defer { busy = false }
        do {
            try await BookMaster.shared.setSeriesBook(
                series: id, book: row.bookId,
                position: (detail?.books.count ?? 0) + 1)
            adding = false
            await load()
        } catch {
            // the pick sheet is up: an alert on the page behind it would not show
            pickError = error.localizedDescription
        }
    }

    private func unfile(_ book: BMSeriesBook) async {
        busy = true
        defer { busy = false }
        do {
            try await BookMaster.shared.setSeriesBook(series: id, book: book.id, remove: true)
            detail?.books.removeAll { $0.id == book.id }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func load() async {
        do {
            detail = try await BookMaster.shared.fetchSeriesDetail(id: id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
