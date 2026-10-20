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
    @State private var coverFetching = false
    @State private var coverFailed = false
    @State private var tint: Color = .ptAccent
    @State private var descriptionExpanded = false
    @State private var confirmRestart = false
    @State private var detent: PresentationDetent = .large

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        Button { changeCover = true } label: {
                            BookCoverView(book: book, cover: cover, showsBadges: false, corner: 16)
                                .frame(width: 186)
                                .overlay {
                                    if coverFetching {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color.black.opacity(0.35))
                                            .overlay { ProgressView().tint(.white) }
                                    }
                                }
                                .shadow(color: tint.opacity(0.35), radius: 18, y: 8)
                                .overlay(alignment: .bottomTrailing) {
                                    if cover != nil {
                                        Image(systemName: "photo.badge.arrow.down")
                                            .font(.caption.weight(.bold))
                                            .padding(7)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .offset(x: 8, y: 8)
                                    }
                                }
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(coverFetching)
                        .accessibilityLabel("Change cover")
                        .accessibilityHint("Finds jacket art online")
                        if cover == nil {
                            Button { changeCover = true } label: {
                                Label("Find a Cover", systemImage: "photo.badge.plus")
                            }
                            .ptButtonStyle(prominent: false)
                            .controlSize(.small)
                        }
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
            .background(CoverTintBackdrop(tint: tint))
            .task(id: cover.map(ObjectIdentifier.init)) {
                tint = cover?.averageColor.map { Color($0) } ?? .ptAccent
            }
            // a book still in the Drive: ask the catalogues what they know of it, once, as the page opens
            .task(id: book.id) {
                guard cloud != nil, book.bookDescription == nil || book.author.isEmpty, let onLookup else { return }
                lookingUp = true
                await onLookup()
                lookingUp = false
            }
            .sheet(isPresented: $showNotes) { BookNotesView(book: book) }
            .sheet(isPresented: $changeCover) {
                BookLookupSheet(book: book, coverOnly: true) { candidate, _ in
                    guard !candidate.coverURLs.isEmpty else { return }
                    coverFetching = true
                    Task {
                        let ok = await MetadataLookup.applyCover(from: candidate.coverURLs, to: book, library: library)
                        coverFetching = false
                        coverFailed = !ok
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .alert("Couldn't get that cover", isPresented: $coverFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("None of the jackets for that match could be downloaded. Try another.")
        }
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
    /// The lookup sheet — details or jacket only, switched inside it.
    @State private var showLookup = false
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
                coverSection
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
                seeded: (title: title, author: author, isbn: isbn),
                modeSwitchable: true) { candidate, coverOnly in
                    if coverOnly {
                        pickedCovers = candidate.coverURLs
                        pickedImage = nil
                        removeCover = false
                    } else {
                        apply(candidate)
                    }
                }
        }
    }

    // MARK: Cover

    /// The cover on its own: from the photos, from another match's art, or none (the plain jacket) — whatever a
    /// wrong lookup put there.
    /// Whether a jacket file is on disk now — a path check, not a decode: the form redraws on every keystroke.
    private var hasStoredCover: Bool {
        FileManager.default.fileExists(atPath: library.coverURL(for: original).path)
    }

    private var coverSection: some View {
        Section {
            HStack {
                if !removeCover, pickedImage == nil, !pickedCovers.isEmpty {
                    RemoteCover(urls: pickedCovers)
                        .frame(width: 70, height: 105)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    // the thumbnail is cached; cover(for:) would decode the full jacket per redraw
                    BookCoverView(
                        book: original,
                        cover: removeCover ? nil : (pickedImage ?? library.coverThumbnail(for: original, maxPixels: 300)),
                        showsBadges: false, corner: 8)
                        .frame(width: 70)
                }
                if removeCover || pickedImage != nil || !pickedCovers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(removeCover ? "Cover will be removed" : "New cover")
                            .font(.subheadline.weight(.medium))
                        Text("Saved with the book.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Undo") {
                            pickedCovers = []
                            pickedImage = nil
                            removeCover = false
                            photo = nil
                        }
                        .font(.subheadline)
                    }
                }
                Spacer()
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose from Photos…", systemImage: "photo")
            }
            Button {
                showLookup = true
            } label: {
                Label("Look Up Online…", systemImage: "magnifyingglass")
            }
            if (hasStoredCover && !removeCover) || pickedImage != nil || !pickedCovers.isEmpty {
                Button("Remove Cover", role: .destructive) {
                    removeCover = true
                    pickedImage = nil
                    pickedCovers = []
                }
            }
        } header: {
            Text("Cover")
        } footer: {
            Text("A match fills the fields and the cover at once; Cover Only swaps just the jacket.")
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
        // the match's jacket comes with it, over a photo or a removal chosen
        // earlier; a match without one leaves the cover choice as it stood
        if !candidate.coverURLs.isEmpty {
            pickedCovers = candidate.coverURLs
            pickedImage = nil
            removeCover = false
        }
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
/// Same pick, same grid, either job — `modeSwitchable` puts the choice in
/// the sheet itself.
struct BookLookupSheet: View {
    let book: Book
    /// The edit sheet lets the reader swap between details and jacket-only.
    let modeSwitchable: Bool
    /// `coverOnly` tells the caller whether the pick is only the jacket.
    let onPick: (MetadataCandidate, _ coverOnly: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var isbn: String
    /// Cover-only picking leaves the words alone — the caller takes just the
    /// jacket off the match.
    @State private var coverOnly: Bool
    @State private var refining = false
    @State private var scanning = false
    @State private var searching = false
    @State private var candidates: [MetadataCandidate]?
    @State private var sourceFilter: String?
    @State private var previewing: MetadataCandidate?

    /// `seeded` lets the edit sheet start the search from its working fields
    /// rather than the stored book's.
    init(book: Book, seeded: (title: String, author: String, isbn: String)? = nil,
         coverOnly: Bool = false, modeSwitchable: Bool = false,
         onPick: @escaping (MetadataCandidate, _ coverOnly: Bool) -> Void) {
        self.book = book
        self.modeSwitchable = modeSwitchable
        self.onPick = onPick
        _coverOnly = State(initialValue: coverOnly)
        _title = State(initialValue: seeded?.title ?? book.title)
        _author = State(initialValue: seeded?.author ?? book.author)
        _isbn = State(initialValue: seeded?.isbn ?? book.isbn ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if modeSwitchable {
                    Picker("", selection: $coverOnly) {
                        Text("Details & Cover").tag(false)
                        Text("Cover Only").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                DisclosureGroup("Refine", isExpanded: $refining) {
                    TextField("Author", text: $author)
                    TextField("ISBN", text: $isbn)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                .submitLabel(.search)
                .onSubmit { search() }
                resultsSection
            }
            .navigationTitle(coverOnly ? "Pick a Cover" : "Find Details")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $title,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Title or ISBN")
            .onSubmit(of: .search) { search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { scanning = true } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Scan barcode")
                }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    BMScanView { code in
                        isbn = code
                        refining = true
                        search()
                    }
                }
            }
            .sheet(item: $previewing) { c in
                CoverPreviewSheet(candidate: c, coverOnly: coverOnly) { pick(c) }
            }
            .task { search() }
        }
        // a grid of jackets wants the height: at the medium stop one row shows under the fields
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The search state and the matches — one status row, then the grid.
    @ViewBuilder
    private var resultsSection: some View {
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
                    // a pick is only a jacket when it brings one
                    let pickable = coverOnly ? candidates.filter { !$0.coverURLs.isEmpty } : candidates
                    let keys = sources(in: pickable)
                    // a chip set on a previous search can name a source this one lacks
                    let active = keys.contains(sourceFilter ?? "") ? sourceFilter : nil
                    if keys.count >= 2 {
                        sourceChips(keys, active: active)
                    }
                    if pickable.isEmpty {
                        Text("No jackets turned up for that — the matches have no cover art.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    let shown = pickable.filter { active == nil || chipKey($0) == active }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 126), spacing: 14)], spacing: 18) {
                        ForEach(shown) { c in card(c) }
                    }
                    .padding(.vertical, 8)
                    .ptAnimation(.smooth(duration: 0.35), value: shown.map(\.id))
                    Text(coverOnly
                        ? "Tap a jacket to see it full size — the book's words stay as they are."
                        : "Tap a cover to take its details — the jacket comes with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One match: art, title, source — a ring and a capsule mark the book itself.
    private func card(_ c: MetadataCandidate) -> some View {
        Button {
            if coverOnly { previewing = c } else { pick(c) }
        } label: {
            VStack(spacing: 6) {
                RemoteCover(urls: c.coverURLs)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if isCurrent(c) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ptAccent, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isCurrent(c) {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.ptAccent, in: Capsule())
                                .padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                Text(c.title).font(.caption.weight(.medium)).lineLimit(2)
                Text(c.authors).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text([c.year, c.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(.primary)
        .accessibilityHint(coverOnly ? "Shows this jacket full size" : "Takes this match's details and jacket")
        .contextMenu {
            Button { previewing = c } label: {
                Label("Preview Cover", systemImage: "eye")
            }
        }
    }

    /// The match that is this book already — same shelf pin, work id or ISBN.
    private func isCurrent(_ c: MetadataCandidate) -> Bool {
        (c.bookmasterId != nil && c.bookmasterId == book.bookmasterId)
            || (c.openLibraryId != nil && c.openLibraryId == book.openLibraryId)
            || (ISBN.normalize(c.isbn ?? "") != nil && ISBN.normalize(c.isbn ?? "") == book.isbn)
    }

    /// The chip a match sorts under: BookMaster's shelf rows and catalogue
    /// hits share one, the rest go by the name the source gave.
    private func chipKey(_ c: MetadataCandidate) -> String {
        c.source.contains("BookMaster") ? "BookMaster" : c.source
    }

    /// The chip names, in the order the matches first bring them.
    private func sources(in pickable: [MetadataCandidate]) -> [String] {
        pickable.reduce(into: [String]()) { keys, c in
            let key = chipKey(c)
            if !keys.contains(key) { keys.append(key) }
        }
    }

    /// "All" plus one chip per source, shown when the answers mix sources.
    private func sourceChips(_ keys: [String], active: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip("All", active: active == nil) { sourceFilter = nil }
                ForEach(keys, id: \.self) { key in
                    sourceChip(key, active: active == key) { sourceFilter = key }
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    private func sourceChip(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.ptAccent : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ candidate: MetadataCandidate) {
        onPick(candidate, coverOnly)
        dismiss()
    }

    private func search() {
        sourceFilter = nil
        let ask = title.trimmingCharacters(in: .whitespaces)
        guard !ask.isEmpty || !isbn.trimmingCharacters(in: .whitespaces).isEmpty else {
            candidates = []
            return
        }
        searching = true
        candidates = nil
        // digits in the search box name the book outright: the ISBN itself, not a title
        let asISBN = ISBN.normalize(ask) != nil
        let askTitle = asISBN ? "" : title
        let askISBN = asISBN ? title : isbn
        Task {
            // the first source to answer shows at once; the rest add to the list as they come
            let results = await MetadataLookup.search(
                title: askTitle, author: author, isbn: askISBN,
                progress: { found in if !found.isEmpty { candidates = found } })
            candidates = results
            searching = false
        }
    }
}

/// A jacket at full size before it is taken — reached by a tap in cover-only
/// mode, or "Preview Cover" on a long press in either.
private struct CoverPreviewSheet: View {
    let candidate: MetadataCandidate
    let coverOnly: Bool
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                RemoteCover(urls: candidate.coverURLs, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                Text(candidate.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !candidate.authors.isEmpty {
                    Text(candidate.authors)
                        .foregroundStyle(.secondary)
                }
                Text([candidate.year, candidate.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    // the pick dismisses the lookup sheet, which takes this one with it
                    onUse()
                    dismiss()
                } label: {
                    Text(coverOnly ? "Use This Cover" : "Take Details & Cover")
                        .frame(maxWidth: .infinity)
                }
                .ptButtonStyle(prominent: true)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}
