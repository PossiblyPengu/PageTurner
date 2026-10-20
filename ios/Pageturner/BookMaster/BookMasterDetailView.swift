import SwiftUI

/// One book the way BookMaster's detail page knows it: where it stands on your
/// shelf (and the ways to move it), the sittings logged, the lines kept, the
/// shared thread — and where the other reader has it when they do. Reached by
/// shelf pin, by catalogue id, or by a title folded the way a push resolves.
struct BookMasterDetailView: View {
    var pin: String? = nil
    var bookId: String? = nil
    var title: String? = nil
    var author: String? = nil

    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var detail: BMBookDetail?
    @State private var error: String?
    @State private var loading = true
    @State private var reveal = false
    @State private var busy = false
    @State private var draft = ""
    @State private var note = ""
    @State private var info: String?
    @State private var importing = false
    @State private var confirmRemove = false
    @State private var logging = false
    @State private var editing = false
    @State private var loggedMinutes: Int? = nil
    /// The open log sheet was filled from the running timer, which stops when it saves.
    @State private var timedLog = false
    @State private var timerNow = Date()
    @State private var tint: Color = .ptAccent
    @State private var blurbExpanded = false

    /// The library's copy of this book, when there is one — for the Read button.
    private var local: Book? {
        guard let row = detail?.book else { return nil }
        return library.books.first { BMShelf.match($0, in: [row]) != nil }
    }

    /// How a push names the book — pinned whenever the shelf row is known.
    private var ref: BMBookRef {
        BMBookRef(
            title: detail?.book?.title ?? detail?.catalogue?.title ?? title ?? "",
            author: detail?.book?.author ?? detail?.catalogue?.author ?? author ?? "",
            isbn: detail?.book?.isbn ?? detail?.catalogue?.isbn,
            openLibraryId: detail?.book?.openLibraryId ?? detail?.catalogue?.openLibraryId,
            userBookId: detail?.book?.userBookId)
    }

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        presented(
            List {
                if let detail {
                    headerSection(detail)
                    if let book = detail.book { shelfSection(book) }
                    if let book = local {
                        Section {
                            Button {
                                router.open(book, library: library)
                            } label: {
                                Label(book.isAudio ? "Listen in Pageturner" : "Read in Pageturner",
                                      systemImage: book.isAudio ? "headphones" : "book.open")
                            }
                        }
                    } else {
                        addFileSection
                    }
                    if let theirs = detail.theirs { theirsSection(theirs) }
                    if !detail.sessions.isEmpty { sessionsSection(detail.sessions) }
                    quotesSection(detail.quotes)
                    commentsSection(detail)
                    suggestSection
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                if let info { Section { Text(info).foregroundStyle(.secondary) } }
                if let error, detail == nil { Section { Text(error).foregroundStyle(.secondary) } }
            }
            .scrollContentBackground(.hidden)
            .background(CoverTintBackdrop(tint: tint))
            // a failed write is told where the reader is looking, not in a footer at the bottom of a long list
            .alert("BookMaster", isPresented: Binding(get: { error != nil && detail != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .navigationTitle(detail?.catalogue?.title ?? detail?.book?.title ?? title ?? "Book")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
        )
    }

    /// The dialogs and sheets the page presents, split off the List's chain.
    private func presented<V: View>(_ content: V) -> some View {
        content
            .confirmationDialog(
                "Remove from your shelf?", isPresented: $confirmRemove, titleVisibility: .visible
            ) {
                Button("Remove from Shelf", role: .destructive) { Task { await unshelve() } }
            } message: {
                Text("Its sessions, quotes and comments go with it on BookMaster. Any file here stays.")
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: LibraryView.pickerTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                Task { await bringIn(urls) }
            }
            .sheet(isPresented: $logging, onDismiss: { loggedMinutes = nil; timedLog = false }) {
                if let book = detail?.book {
                    BMLogSheet(row: book, initialMinutes: loggedMinutes) {
                        loggedMinutes = nil
                        if timedLog { BMReadingTimer.shared.stop() }
                        Task { await load() }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                if let bookId = detail?.catalogue?.id {
                    BMEditSheet(bookId: bookId, detail: detail) { Task { await load() } }
                }
            }
    }

    // MARK: Sections

    private func headerSection(_ detail: BMBookDetail) -> some View {
        Section {
            VStack(spacing: 16) {
                cover
                VStack(spacing: 4) {
                    Text(detail.catalogue?.title ?? detail.book?.title ?? title ?? "")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let author = detail.catalogue?.author ?? detail.book?.author ?? author,
                       !author.isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    let meta = [
                        detail.catalogue?.publishedYear.map(String.init),
                        detail.catalogue?.totalPages.map { "\($0) pages" },
                    ].compactMap { $0 } + (detail.catalogue?.genreList.prefix(2) ?? [])
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
            if let blurb = detail.catalogue?.description, !blurb.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(blurb)
                        .font(.subheadline)
                        .lineLimit(blurbExpanded ? nil : 5)
                    if blurb.count > 240 {
                        Button(blurbExpanded ? "Less" : "More") {
                            withAnimation { blurbExpanded.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }

    /// The cover BookMaster knows: a pushed one is a URL of its own, then Open Library's.
    private var cover: some View {
        let isbn = detail?.catalogue?.isbn ?? detail?.book?.isbn
        let olid = detail?.catalogue?.openLibraryId ?? detail?.book?.openLibraryId
        return RemoteCover(
            urls: bmCoverURLs(coverUrl: detail?.catalogue?.coverUrl, isbn: isbn, openLibraryId: olid),
            icon: (detail?.book?.isAudio ?? false) ? "headphones" : "book.closed",
            onLoad: { image in
                if let c = image.averageColor { tint = Color(c) }
            })
        .frame(width: 186)
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: tint.opacity(0.35), radius: 18, y: 8)
    }

    /// Where the row stands, and the ways to move it — the edits BookMaster's
    /// library page makes, all through the one shelf call.
    private func shelfSection(_ book: BMShelfRow) -> some View {
        Section("On your shelf") {
            Picker("Status", selection: statusBinding) {
                ForEach(BMShelfStatus.allCases) { s in
                    Text(s.shortLabel).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .disabled(busy)

            if let percent = book.percent {
                LabeledContent("Position", value: "\(Int(percent.rounded()))%")
            }
            paceRow(book)
            HStack {
                Text("Rating")
                Spacer()
                HStack(spacing: 0) {
                    ForEach(1...5, id: \.self) { star in
                        Button { Task { await setRating(star == book.rating ? nil : star) } } label: {
                            Image(systemName: star <= (book.rating ?? 0) ? "star.fill" : "star")
                                .foregroundStyle(Color.ptAccent)
                                .frame(minWidth: 36, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        .accessibilityAddTraits(star == book.rating ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rating")
            }
            Toggle("Up next", isOn: upNextBinding).disabled(busy)
            Button { logging = true } label: {
                Label("Log a session", systemImage: "plus.circle")
            }
            timerRow(book)
            if detail?.catalogue?.id != nil {
                Button { editing = true } label: {
                    Label("Edit book", systemImage: "pencil")
                }
            }
            Button("Remove from Shelf", role: .destructive) { confirmRemove = true }
        }
    }

    /// The web's pace line: pages a day from the last seven sittings, and the
    /// date that pace lands on the end — nil until it has something to say.
    @ViewBuilder
    private func paceRow(_ book: BMShelfRow) -> some View {
        // The shelf row carries percent, not pages — convert it back with the
        // catalogue count so the pace math sees real pages.
        let pages = detail?.catalogue?.totalPages ?? book.totalPages
        let at = book.percent.map { $0 / 100 * Double(pages ?? 0) }
        if let estimate = BMPace.estimate(
            sessions: detail?.sessions ?? [],
            totalPages: pages,
            currentPage: at) {
            Label(BMPace.label(estimate), systemImage: "chart.line.uptrend.xyaxis")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The reading timer, as this book sees it: idle → "Time me"; running here
    /// → a live clock with stop (which logs) and cancel; running elsewhere → a
    /// quiet note, since one clock times one book.
    @ViewBuilder
    private func timerRow(_ book: BMShelfRow) -> some View {
        let timer = BMReadingTimer.shared
        if let run = timer.run, run.pin == book.userBookId {
            HStack {
                Label(clock(max(0, timerNow.timeIntervalSince(run.startedAt))), systemImage: "timer")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.ptAccent)
                Spacer()
                Button("Stop & log") {
                    // the clock keeps running until the log is saved
                    loggedMinutes = min(Int((timer.elapsed / 60).rounded(.up)), 12 * 60)
                    timedLog = true
                    logging = true
                }
                .font(.subheadline)
                Button("Cancel") { timer.cancel() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { timerNow = $0 }
        } else {
            Button { timerNow = Date(); timer.start(pin: book.userBookId, title: book.title) } label: {
                Label("Time me", systemImage: "timer")
            }
            .disabled(timer.run != nil)
        }
        if let run = timer.run, run.pin != book.userBookId {
            Text("“\(run.title)” is on the clock — stop it there first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// The status control writes through the bridge and the cached row follows.
    private var statusBinding: Binding<BMShelfStatus> {
        Binding(
            get: { BMShelfStatus(rawValue: detail?.book?.status ?? "") ?? .wantToRead },
            set: { s in Task { await setStatus(s) } }
        )
    }

    private var upNextBinding: Binding<Bool> {
        Binding(
            get: { detail?.book?.upNext != nil },
            set: { on in Task { await setUpNext(on) } }
        )
    }

    /// A file for a book the shelf knows but this phone does not.
    private var addFileSection: some View {
        Section {
            Button { importing = true } label: {
                Label("Add a File to Read Here…", systemImage: "square.and.arrow.down")
            }
        } footer: {
            Text("Optional. If you have the EPUB, PDF or audio, add it and Pageturner ties it to this shelf entry so your place and rating stay in step.")
        }
    }

    /// Where the other reader has it — never more than BookMaster itself would show.
    private func theirsSection(_ theirs: BMTheirs) -> some View {
        Section("With \(theirs.name)") {
            LabeledContent("Status", value: BMShelf.label(forStatus: theirs.status))
            if let percent = theirs.percent {
                LabeledContent("Position", value: "\(Int(percent.rounded()))%")
            }
            if let rating = theirs.rating, rating > 0 {
                LabeledContent("Rating", value: String(repeating: "★", count: min(rating, 5)))
            }
        }
    }

    /// The sittings BookMaster has logged, newest first — a wrong one is yours to take back.
    private func sessionsSection(_ sessions: [BMSession]) -> some View {
        Section("Sessions") {
            ForEach(sessions.prefix(12)) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.day(session.sessionDate))
                        Text(Self.sessionLine(session))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) { Task { await takeBack(.session, id: session.id) } }
                }
            }
            if sessions.count > 12 {
                Text("…and \(sessions.count - 12) earlier").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// The kept lines — a note of your own, deletable the same way.
    private func quotesSection(_ quotes: [BMQuote]) -> some View {
        Section(quotes.isEmpty ? "Quotes & notes" : "Quotes & notes (\(quotes.count))") {
            if quotes.isEmpty {
                Text("None kept yet — hold a line in the reader to save one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(quotes.prefix(10)) { quote in
                VStack(alignment: .leading, spacing: 3) {
                    Text(quote.content).lineLimit(4)
                    HStack(spacing: 6) {
                        if quote.isNote { Text("Note") }
                        if let page = quote.pageNumber { Text("· p. \(page)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) { Task { await takeBack(.quote, id: quote.id) } }
                }
            }
            if quotes.count > 10 {
                NavigationLink { BookMasterQuotesView(pin: pin) } label: {
                    Text("All \(quotes.count)")
                }
            }
        }
    }

    /// The shared thread, gated the way the bridge gates it — sealed ones
    /// open only when you ask to be spoiled.
    private func commentsSection(_ detail: BMBookDetail) -> some View {
        Section("Comments") {
            if detail.comments.isEmpty {
                Text("Nothing said yet").foregroundStyle(.secondary)
            }
            ForEach(detail.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(comment.userId == detail.you ? "You" : comment.displayName)
                            .font(.subheadline.weight(.semibold))
                        if let at = comment.atPercent {
                            Text("at \(Int(at.rounded()))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let content = comment.content {
                        Text(content)
                    } else {
                        Label("Sealed until you get further in", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if comment.userId == detail.you {
                        Button("Remove", role: .destructive) { Task { await takeBack(.comment, id: comment.id) } }
                    }
                }
            }
            if detail.comments.contains(where: { $0.ahead }), !reveal {
                Button("Reveal the sealed ones") { Task { await load(reveal: true) } }
                    .font(.footnote)
            }
            TextField("Say something about this book", text: $draft, axis: .vertical)
                .lineLimit(1...4)
            Button("Post") { Task { await post() } }
                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Offer it to the other reader.
    private var suggestSection: some View {
        Section("Suggest it") {
            TextField("Optional note", text: $note, axis: .vertical)
                .lineLimit(1...3)
            Button("Suggest to the other reader") { Task { await suggest() } }
                .disabled(busy)
        }
    }

    // MARK: Doing

    private func load(reveal: Bool = false) async {
        do {
            detail = try await BookMaster.shared.fetchBookDetail(
                pin: pin, bookId: bookId, title: title, author: author, reveal: reveal)
            self.reveal = reveal
            error = nil
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
        loading = false
    }

    /// Apply the row the bridge handed back — the answer is the new truth.
    private func apply(_ reply: BMShelfWriteReply) {
        if let fresh = reply.userBook { detail?.book = fresh }
    }

    private func setStatus(_ status: BMShelfStatus) async {
        await edit { try await BookMaster.shared.shelve(pin: detail?.book?.userBookId, status: status) }
    }

    private func setRating(_ stars: Int?) async {
        await edit { try await BookMaster.shared.shelve(pin: detail?.book?.userBookId, rating: .some(stars)) }
    }

    private func setUpNext(_ on: Bool) async {
        await edit { try await BookMaster.shared.shelve(pin: detail?.book?.userBookId, upNext: on) }
    }

    private func unshelve() async {
        guard let pin = detail?.book?.userBookId else { return }
        busy = true
        defer { busy = false }
        do {
            try await BookMaster.shared.shelve(pin: pin, unshelve: true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The shared busy/error wrap for the small shelf writes.
    private func edit(_ work: () async throws -> BMShelfWriteReply) async {
        busy = true
        defer { busy = false }
        do {
            apply(try await work())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func takeBack(_ kind: BookMaster.BMRemovable, id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await BookMaster.shared.remove(kind, id: id)
            switch kind {
            case .session: detail?.sessions.removeAll { $0.id == id }
            case .quote: detail?.quotes.removeAll { $0.id == id }
            case .comment: detail?.comments.removeAll { $0.id == id }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func post() async {
        busy = true
        defer { busy = false }
        do {
            try await BookMaster.shared.postComment(
                ref: ref, content: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""
            error = nil
            await load(reveal: reveal)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggest() async {
        busy = true
        defer { busy = false }
        do {
            let to = try await BookMaster.shared.suggest(ref: ref, note: note)
            info = "Suggested to \(to ?? "the other reader")"
            note = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
            info = nil
        }
    }

    /// Import, and when that made exactly one new book, tie it to this row whatever its file says it is called.
    private func bringIn(_ urls: [URL]) async {
        let before = Set(library.books.map(\.id))
        await library.importFiles(urls)
        let added = library.books.filter { !before.contains($0.id) }
        if added.count == 1, let pin = detail?.book?.userBookId {
            library.updateBookMaster(added[0].id) { $0.bookmasterId = pin }
        }
        await BookMaster.shared.pullShelf(into: library)
    }

    // MARK: Words

    private static func day(_ iso: String?) -> String {
        guard let iso else { return "A sitting" }
        return iso
    }

    private static func sessionLine(_ session: BMSession) -> String {
        var parts: [String] = []
        if let minutes = session.durationMinutes {
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let pages = session.pagesRead, pages > 0 {
            parts.append("\(Int(pages)) pages")
        }
        if let from = session.listenedStart, let to = session.listenedEnd, to > from {
            parts.append("\(Int(to - from)) min heard")
        }
        return parts.isEmpty ? "Logged" : parts.joined(separator: " · ")
    }
}

/// Jacket guesses by the ids the catalogue knows — the same ladder
/// BMShelfRow.coverURLs climbs: stored cover first, then Open Library by ISBN
/// and work id, each falling through on a miss.
func bmCoverURLs(coverUrl: String? = nil, isbn: String?, openLibraryId: String?) -> [URL] {
    var urls = coverUrl.flatMap { URL(string: $0) }.map { [$0] } ?? []
    urls += CoverLinks.isbn(isbn) + CoverLinks.openLibraryWork(openLibraryId)
    return urls
}
