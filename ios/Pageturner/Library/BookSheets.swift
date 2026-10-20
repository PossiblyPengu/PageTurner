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
    /// Play an audiobook from the Drive without downloading it.
    var onStream: (() -> Void)? = nil
    var onRemoveDownload: () -> Void = {}
    /// Looks the book up online (a Drive book has only a name until it is downloaded); true when something was found.
    var onLookup: (() async -> Void)? = nil
    @State private var lookingUp = false
    @EnvironmentObject private var library: LibraryStore
    @State private var picked: Int?
    @State private var showNotes = false
    @State private var changeCover = false
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
                if book.isAudio, let onStream {
                    Button(action: onStream) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Listen Now")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .ptButtonStyle(prominent: true)
                    .controlSize(.large)
                }
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
                    VStack(spacing: 16) {
                        Button { changeCover = true } label: {
                            BookCoverView(book: book, cover: cover, showsBadges: false, corner: 16)
                                .frame(width: 186)
                                .shadow(color: tint.opacity(0.35), radius: 18, y: 8)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "photo.badge.arrow.down")
                                        .font(.caption.weight(.bold))
                                        .padding(7)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .offset(x: 8, y: 8)
                                }
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Change cover")
                        .accessibilityHint("Finds jacket art online")
                        VStack(spacing: 4) {
                            Text(book.title)
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(book.ext.uppercased())
                                if let year = book.year { Text("· \(year)") }
                                if let status = book.bmStatus { Text("· \(BMShelf.label(forStatus: status))") }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        if let p = book.progression, p > 0.001, !isFinished {
                            HStack(spacing: 10) {
                                ProgressView(value: p)
                                    .tint(tint)
                                Text("\(Int((p * 100).rounded()))%")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 240)
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
                    .padding(.vertical, 10)
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
                    Button("Change Cover…") { changeCover = true }
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
            .sheet(isPresented: $changeCover) {
                BookLookupSheet(book: book, coverOnly: true) { candidate in
                    guard !candidate.coverURLs.isEmpty else { return }
                    Task { await MetadataLookup.applyCover(from: candidate.coverURLs, to: book, library: library) }
                }
            }
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
    /// Jacket guesses the picked match will bring (lookup) or the jacket
    /// picked online on its own — either way a chain `applyCover` walks.
    @State private var pickedCovers: [URL] = []
    /// A cover chosen from the photos: written on save.
    @State private var pickedImage: UIImage?
    @State private var removeCover = false
    @State private var photo: PhotosPickerItem?
    /// The lookup sheet, in take-everything or jacket-only mode.
    @State private var showLookup = false
    @State private var pickCoverOnly = false
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
                    Button("Find Details Online") { showLookup = true }
                    Text("A match fills the fields and the cover at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showLookup) {
            BookLookupSheet(
                book: original,
                seeded: (title: title, author: author, isbn: isbn)) { candidate in
                    apply(candidate)
                }
        }
        .sheet(isPresented: $pickCoverOnly) {
            // the same grid, jacket-only: picking a cover is the same action
            BookLookupSheet(
                book: original,
                seeded: (title: title, author: author, isbn: isbn),
                coverOnly: true) { candidate in
                    pickedCovers = candidate.coverURLs
                    pickedImage = nil
                    removeCover = false
                }
        }
    }

    // MARK: Cover

    /// The cover on its own: from the photos, from another match's art, or none (the plain jacket) — whatever a
    /// wrong lookup put there.
    private var coverSection: some View {
        Section {
            HStack {
                if !removeCover, pickedImage == nil, !pickedCovers.isEmpty {
                    RemoteCover(urls: pickedCovers)
                        .frame(width: 70, height: 105)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    BookCoverView(
                        book: original, cover: removeCover ? nil : (pickedImage ?? library.cover(for: original)),
                        showsBadges: false, corner: 8)
                        .frame(width: 70)
                }
                Spacer()
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose from Photos…", systemImage: "photo")
            }
            Button {
                pickCoverOnly = true
            } label: {
                Label("Find Another Cover…", systemImage: "magnifyingglass")
            }
            if library.cover(for: original) != nil || pickedImage != nil || !pickedCovers.isEmpty {
                Button("Remove Cover", role: .destructive) {
                    removeCover = true
                    pickedImage = nil
                    pickedCovers = []
                }
        } header: {
            Text("Cover")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    pickedImage = image
                    pickedCovers = []
                    removeCover = false
                }
            }
        }
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
        pickedCovers = candidate.coverURLs
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
        } else if !pickedCovers.isEmpty {
            Task { await MetadataLookup.applyCover(from: pickedCovers, to: book, library: library) }
        }
    }
}

/// Finding a book online. One grid of big covers and one action — tapping a
/// cover hands back the match; the caller decides whether that takes the
/// fields and jacket (the edit sheet) or the jacket alone ("Change Cover").
/// Same pick, same grid, either job.
struct BookLookupSheet: View {
    let book: Book
    /// Cover-only picking leaves the words alone — the caller takes just the
    /// jacket off the match.
    var coverOnly = false
    let onPick: (MetadataCandidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var isbn: String
    @State private var searching = false
    @State private var candidates: [MetadataCandidate]?

    /// `seeded` lets the edit sheet start the search from its working fields
    /// rather than the stored book's.
    init(book: Book, seeded: (title: String, author: String, isbn: String)? = nil,
         coverOnly: Bool = false, onPick: @escaping (MetadataCandidate) -> Void) {
        self.book = book
        self.coverOnly = coverOnly
        self.onPick = onPick
        _title = State(initialValue: seeded?.title ?? book.title)
        _author = State(initialValue: seeded?.author ?? book.author)
        _isbn = State(initialValue: seeded?.isbn ?? book.isbn ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("ISBN", text: $isbn)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                Section {
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
                        Button("Search Again") { search() }
                    }
                    if let candidates {
                        if candidates.isEmpty {
                            Text("No matches found — check the title and author, and the connection.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 126), spacing: 14)], spacing: 18) {
                                ForEach(candidates) { c in
                                    Button { pick(c) } label: {
                                        VStack(spacing: 6) {
                                            RemoteCover(urls: c.coverURLs)
                                                .frame(maxWidth: .infinity)
                                                .aspectRatio(2 / 3, contentMode: .fit)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                                            Text(c.title).font(.caption.weight(.medium)).lineLimit(2)
                                            Text(c.authors).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                            Text([c.year, c.source].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    }
                                    .foregroundStyle(.primary)
                                    .accessibilityHint(coverOnly ? "Uses this jacket" : "Takes this match's details and jacket")
                                }
                            }
                            .padding(.vertical, 8)
                            Text(coverOnly
                                ? "Tap a jacket to use it — the book's words stay as they are."
                                : "Tap a cover to take its details — the jacket comes with it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(coverOnly ? "Pick a Cover" : "Find Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { search() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func pick(_ candidate: MetadataCandidate) {
        onPick(candidate)
        dismiss()
    }

    private func search() {
        searching = true
        candidates = nil
        Task {
            // the first source to answer shows at once; the rest add to the list as they come
            let results = await MetadataLookup.search(
                title: title, author: author, isbn: isbn,
                progress: { found in if !found.isEmpty { candidates = found } })
            candidates = results
            searching = false
        }
    }
}
