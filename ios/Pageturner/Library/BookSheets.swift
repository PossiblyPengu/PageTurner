import PhotosUI
import SwiftUI

struct BookDetailSheet: View {
    let book: Book
    let cover: UIImage?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onShelves: () -> Void
    let onFinish: () -> Void
    let onRestart: () -> Void
    /// Rating, when the book can be rated on BookMaster (it is linked).
    var onRate: ((Int) -> Void)? = nil
    /// A book from Google Drive that is not on the phone (nil for any other): waiting, coming down, or stuck — and
    /// how far it has got.
    var cloud: DriveDownloads.Badge? = nil
    var downloadState: DriveDownloads.State? = nil
    var onDownload: () -> Void = {}
    var onCancelDownload: () -> Void = {}
    var onRemoveDownload: () -> Void = {}
    /// Looks the book up online (a Drive book has only a name until it is downloaded); true when something was found.
    var onLookup: (() async -> Void)? = nil
    @State private var lookingUp = false
    @State private var picked: Int?
    @State private var showNotes = false
    @State private var tint: Color = .ptAccent
    @State private var descriptionExpanded = false
    @State private var confirmRestart = false

    private var isFinished: Bool { (book.progression ?? 0) >= 0.995 }

    private var openLabel: String {
        let p = book.progression ?? 0
        if isFinished { return book.isAudio ? "Listen Again" : "Read Again" }
        if p > 0.001 { return book.isAudio ? "Continue Listening" : "Continue Reading" }
        return book.isAudio ? "Listen" : "Read"
    }

    /// The place of the Read button for a book that is still in the Drive: Download, its progress, or why it stopped.
    @ViewBuilder
    private var cloudControl: some View {
        switch cloud {
        case .downloading:
            VStack(spacing: 8) {
                if let fraction = downloadState?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel Download", action: onCancelDownload)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
        case .failed:
            VStack(spacing: 10) {
                Text(downloadState?.failure ?? "The download did not finish.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button(action: onDownload) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                    .frame(maxWidth: .infinity)
                }
                .ptButtonStyle(prominent: true)
                .controlSize(.large)
            }
        default:
            VStack(spacing: 6) {
                Button(action: onDownload) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.down")
                        Text("Download")
                    }
                    .frame(maxWidth: .infinity)
                }
                .ptButtonStyle(prominent: true)
                .controlSize(.large)
                if let line = downloadSizeLine {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "412 MB · 12 files": what a download will cost.
    private var downloadSizeLine: String? {
        guard let source = book.drive else { return nil }
        var parts: [String] = []
        let size = GoogleDrive.sizeText(source.bytes)
        if !size.isEmpty { parts.append(size) }
        if source.parts.count > 1 { parts.append("\(source.parts.count) files") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "412 MB of 1.2 GB · file 3 of 12".
    private var progressText: String {
        guard let state = downloadState else { return "Starting…" }
        var parts: [String] = []
        if state.total > 0 {
            parts.append("\(GoogleDrive.sizeText(state.received)) of \(GoogleDrive.sizeText(state.total))")
        } else if state.received > 0 {
            parts.append(GoogleDrive.sizeText(state.received))
        }
        if state.parts > 1 { parts.append("\(min(state.partsDone + 1, state.parts)) of \(state.parts) files") }
        return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
    }

    /// The cover's colour fading into the sheet, so the page belongs to the book.
    private var backdrop: some View {
        LinearGradient(
            colors: [tint.opacity(0.35), Color(.systemGroupedBackground)],
            startPoint: .top, endPoint: .center
        )
        .ignoresSafeArea()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        BookCoverView(book: book, cover: cover, showsBadges: false, corner: 12)
                            .frame(width: 124)
                        VStack(spacing: 4) {
                            Text(book.title)
                                .font(.title3.weight(.bold))
                                .multilineTextAlignment(.center)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if cloud != nil {
                            cloudControl
                        } else {
                            Button(action: onOpen) {
                                // not a Label: inside a List it tints its icon with the accent colour,
                                // which vanishes on the accent-filled button
                                HStack(spacing: 8) {
                                    Image(systemName: book.isAudio ? "play.fill" : "book.fill")
                                    Text(openLabel)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .ptButtonStyle(prominent: true)
                            .controlSize(.large)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                if let blurb = book.bookDescription, !blurb.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(blurb)
                                .font(.subheadline)
                                .lineLimit(descriptionExpanded ? nil : 5)
                            if blurb.count > 240 {
                                Button(descriptionExpanded ? "Less" : "More") {
                                    withAnimation { descriptionExpanded.toggle() }
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
                if lookingUp {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking up details…").foregroundStyle(.secondary)
                        }
                    }
                } else if book.author.isEmpty {
                    Section {
                        Label("The author is missing.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Button("Find Details", action: onEdit)
                    }
                }
                Section {
                    LabeledContent("Format", value: book.ext.uppercased())
                    if let year = book.year { LabeledContent("Year", value: year) }
                    if let isbn = book.isbn { LabeledContent("ISBN", value: isbn) }
                    LabeledContent("Added", value: book.addedAt.formatted(date: .abbreviated, time: .omitted))
                    if let opened = book.lastOpenedAt {
                        LabeledContent("Last opened", value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let p = book.progression {
                        LabeledContent("Progress", value: "\(Int((p * 100).rounded()))%")
                    }
                    if let status = book.bmStatus {
                        LabeledContent("On BookMaster", value: BMShelf.label(forStatus: status)
                            + (book.bmUpNext == true ? " · up next" : ""))
                    }
                    if let remote = book.bmRemotePercent {
                        LabeledContent("BookMaster position", value: "\(Int(remote.rounded()))%")
                    }
                    // rating a book that has not been started would put it on the shelf as being read at 0%
                    if BookMaster.shared.isLinked, BookMaster.shared.syncEnabled, let onRate,
                       (book.progression ?? 0) > 0.001 || book.bmStatus == "reading" || book.bmStatus == "read" {
                        HStack {
                            Text("Your Rating")
                            Spacer()
                            ForEach(1...5, id: \.self) { n in
                                Button {
                                    picked = n
                                    onRate(n)
                                } label: {
                                    Image(systemName: n <= (picked ?? book.bmRating ?? 0) ? "star.fill" : "star")
                                        .foregroundStyle(Color.ptAccent)
                                        .font(.title3)
                                        .frame(minWidth: 36, minHeight: 44)
                                        .contentShape(Rectangle())
                                        .ptSymbolSwap(on: picked)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(n == 1 ? "1 star" : "\(n) stars")
                                .accessibilityAddTraits(n == (picked ?? book.bmRating ?? 0) ? .isSelected : [])
                            }
                        }
                        .sensoryFeedback(.selection, trigger: picked)
                        .onChange(of: book.bmRating) { _, _ in picked = nil }
                    } else if let rating = book.bmRating {
                        LabeledContent("Rating", value: String(repeating: "★", count: max(0, min(5, rating))))
                    }
                    if book.isAudio, book.fileNames.count > 1 {
                        LabeledContent("Tracks", value: "\(book.fileNames.count)")
                    }
                    if let source = book.drive, source.bytes > 0 {
                        LabeledContent("Size", value: GoogleDrive.sizeText(source.bytes))
                    }
                    if book.drive != nil {
                        LabeledContent("Stored in", value: cloud == nil ? "This iPhone and Google Drive" : "Google Drive")
                    }
                    if !book.isAudio {
                        LabeledContent("Bookmarks", value: "\(book.bookmarks.count)")
                    }
                }
                Section {
                    if !isFinished {
                        Button(book.isAudio ? "Mark as Listened" : "Mark as Finished", action: onFinish)
                    }
                    if (book.progression ?? 0) > 0 {
                        Button(book.isAudio ? "Listen from the Beginning" : "Start from the Beginning") { confirmRestart = true }
                            .confirmationDialog("Start over?", isPresented: $confirmRestart, titleVisibility: .visible) {
                                Button(book.isAudio ? "Listen from the Beginning" : "Start from the Beginning", role: .destructive, action: onRestart)
                            } message: {
                                Text("Your place in this book is forgotten.")
                            }
                    }
                    Button(book.collections.isEmpty ? "Add to a Shelf…" : "Shelves: \(book.collections.joined(separator: ", "))", action: onShelves)
                    Button("Edit Details", action: onEdit)
                    if book.drive != nil, cloud == nil {
                        Button("Remove Download", action: onRemoveDownload)
                    }
                    if BookMaster.shared.isLinked {
                        Button("Comments & Suggestions") { showNotes = true }
                    }
                    Button("Remove from Library", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle("Book Info")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(backdrop)
            .task { if let color = cover?.averageColor { tint = Color(color) } }
            // a book still in the Drive: ask the catalogues what they know of it, once, as the page opens
            .task(id: book.id) {
                guard cloud != nil, book.bookDescription == nil || book.author.isEmpty, let onLookup else { return }
                lookingUp = true
                await onLookup()
                lookingUp = false
            }
            .sheet(isPresented: $showNotes) { BookNotesView(book: book) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct BookEditSheet: View {
    @State private var title: String
    @State private var author: String
    @State private var year: String
    @State private var isbn: String
    @State private var summary: String
    @State private var pin: String?
    @State private var openLibraryId: String?
    @State private var searching = false
    @State private var candidates: [MetadataCandidate]?
    @State private var pickedCover: URL?
    /// A cover chosen from the photos: written on save.
    @State private var pickedImage: UIImage?
    @State private var removeCover = false
    @State private var photo: PhotosPickerItem?
    @State private var coverChoices: [MetadataCandidate]?
    @State private var findingCovers = false
    private let original: Book
    private let onSave: (Book) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    init(book: Book, onSave: @escaping (Book) -> Void) {
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _year = State(initialValue: book.year ?? "")
        _isbn = State(initialValue: book.isbn ?? "")
        _summary = State(initialValue: book.bookDescription ?? "")
        _pin = State(initialValue: book.bookmasterId)
        _openLibraryId = State(initialValue: book.openLibraryId)
        original = book
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("Year", text: $year)
                        .keyboardType(.numberPad)
                    TextField("ISBN", text: $isbn)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                Section("Description") {
                    TextField("A few lines about the book", text: $summary, axis: .vertical)
                        .lineLimit(3...10)
                }
                coverSection

                Section("Lookup") {
                    if searching {
                        HStack {
                            ProgressView()
                            Text(BookMaster.shared.isLinked
                                ? "Searching BookMaster, Google Books and Open Library…"
                                : "Searching Google Books and Open Library…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Find Details Online") { lookup() }
                    }
                    if let candidates {
                        if candidates.isEmpty {
                            Text("No matches found — check the title and author, and the connection.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidates) { c in
                            Button { apply(c) } label: {
                                HStack(spacing: 10) {
                                    AsyncImage(url: c.coverURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "book.closed")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 34, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(c.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text([c.year, c.source].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func lookup() {
        searching = true
        candidates = nil
        Task {
            // the first source to answer shows at once; the rest add to the list as they come
            let results = await MetadataLookup.search(title: title, author: author) { found in
                if !found.isEmpty { candidates = found }
            }
            candidates = results
            searching = false
        }
    }

    // MARK: Cover

    /// The cover on its own: from the photos, from another match's art, or none (the plain jacket) — whatever a
    /// wrong lookup put there.
    private var coverSection: some View {
        Section {
            HStack {
                BookCoverView(
                    book: original, cover: removeCover ? nil : (pickedImage ?? library.cover(for: original)),
                    showsBadges: false, corner: 8)
                    .frame(width: 70)
                Spacer()
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose from Photos…", systemImage: "photo")
            }
            Button {
                Task { await findCovers() }
            } label: {
                HStack {
                    Label("Find Another Cover…", systemImage: "magnifyingglass")
                    if findingCovers { Spacer(); ProgressView() }
                }
            }
            .disabled(findingCovers)
            if let coverChoices {
                if coverChoices.isEmpty {
                    Text("No covers turned up for that title and author.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(coverChoices) { c in
                                Button {
                                    pickedCover = c.coverURL
                                    pickedImage = nil
                                    removeCover = false
                                } label: {
                                    AsyncImage(url: c.coverURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.secondary.opacity(0.15)
                                    }
                                    .frame(width: 64, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay {
                                        if pickedCover == c.coverURL {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.ptAccent, lineWidth: 3)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if library.cover(for: original) != nil || pickedImage != nil || pickedCover != nil {
                Button("Remove Cover", role: .destructive) {
                    removeCover = true
                    pickedImage = nil
                    pickedCover = nil
                }
            }
        } header: {
            Text("Cover")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    pickedImage = image
                    pickedCover = nil
                    removeCover = false
                }
            }
        }
    }

    private func findCovers() async {
        findingCovers = true
        let found = await MetadataLookup.search(
            title: title.trimmingCharacters(in: .whitespaces), author: author.trimmingCharacters(in: .whitespaces))
        coverChoices = found.filter { $0.coverURL != nil }
        findingCovers = false
    }

    /// Take everything the match knows; blanks in the match leave the field alone.
    private func apply(_ candidate: MetadataCandidate) {
        title = candidate.title
        author = candidate.authors
        if !candidate.year.isEmpty { year = candidate.year }
        if !candidate.summary.isEmpty { summary = candidate.summary }
        if let isbn = candidate.isbn { self.isbn = isbn }
        if let olid = candidate.openLibraryId { openLibraryId = olid }
        // a shelf row the match names is the one to push to — never a guess
        if let id = candidate.bookmasterId { pin = id }
        pickedCover = candidate.coverURL
    }

    private func save() {
        // start from the book as stored now: the one this sheet opened with may have
        // lost reading progress, bookmarks or shelves since
        var book = library.books.first(where: { $0.id == original.id }) ?? original
        book.title = title.trimmingCharacters(in: .whitespaces)
        book.author = author.trimmingCharacters(in: .whitespaces)
        let trimmedYear = year.trimmingCharacters(in: .whitespaces)
        book.year = trimmedYear.isEmpty ? nil : trimmedYear
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        book.bookDescription = trimmedSummary.isEmpty ? nil : trimmedSummary
        // an ISBN that doesn't check out is kept out of BookMaster matching
        book.isbn = ISBN.normalize(isbn)
        book.openLibraryId = openLibraryId
        book.bookmasterId = pin
        onSave(book)
        if removeCover {
            try? FileManager.default.removeItem(at: library.coverURL(for: book))
            library.coverChanged()
        } else if let pickedImage, let jpeg = pickedImage.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: library.coverURL(for: book))
            library.coverChanged()
        } else if let pickedCover {
            Task { await MetadataLookup.applyCover(from: pickedCover, to: book, library: library) }
        }
    }
}
