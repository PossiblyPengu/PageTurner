import SwiftUI

/// A book's cover — the real art when there is some, otherwise a designed
/// jacket in a colour chosen from the title so the shelf isn't a wall of one
/// gradient. Small badges mark audiobooks and how far you are.
struct BookCoverView: View {
    let book: Book
    let cover: UIImage?
    var showsBadges = true
    var corner: CGFloat = 10
    /// nil outside select mode; true/false draws the tick.
    var selected: Bool?
    /// The book's file has gone from the device.
    var missing = false
    /// A book from Google Drive that has not come down (or is on its way): nil for any other.
    var cloud: DriveDownloads.Badge?
    /// A PDF that has a text version.
    var hasTextVersion = false

    var body: some View {
        // The 2:3 box is a clear base and the art an overlay on it: an overlay never changes its
        // base's size, so a PDF's or a comic's cover (not exactly 2:3) is cropped to the cell instead
        // of making the cell wider than its neighbours.
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    jacket
                }
            }
            .overlay(alignment: .bottom) {
                if showsBadges { badges }
            }
            // a cover is artwork with a fixed shape: its lettering and badges don't grow with the text size
            .dynamicTypeSize(...DynamicTypeSize.large)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.ptAccent : Color.white)
                        .background(Circle().fill(Color.black.opacity(selected ? 0 : 0.25)))
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            .accessibilityHidden(true)
    }

    private var jacket: some View {
        let base = Self.colour(for: book.title)
        return ZStack {
            LinearGradient(colors: [base, base.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // a light hue under white lettering needs a little dark behind it
            Color.black.opacity(0.2)
            VStack(spacing: 6) {
                Text(book.title)
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(.caption2, design: .serif))
                        .opacity(0.95)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }

    private var badges: some View {
        HStack(alignment: .bottom) {
            if let cloud {
                CloudBadge(badge: cloud)
            }
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(6)
                    .ptGlass(in: Circle())
                    .accessibilityLabel("File missing")
            }
            if hasTextVersion {
                Image(systemName: "doc.plaintext")
                    .font(.caption2.weight(.bold))
                    .padding(6)
                    .ptGlass(in: Circle())
                    .accessibilityLabel("Has a text version")
            }
            if book.isAudio {
                Image(systemName: "headphones")
                    .font(.caption2.weight(.bold))
                    .padding(6)
                    .ptGlass(in: Circle())
            }
            Spacer(minLength: 0)
            if let p = book.progression, p > 0 {
                Text("\(Int((p * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .ptGlassCapsule()
            }
        }
        .padding(6)
    }

    /// A warm, book-cloth colour from the title — the same title always gets the same one.
    static func colour(for title: String) -> Color {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.55)
    }
}

/// What a cover says about a Drive book that is not on the phone: waiting to be downloaded, coming down, or stuck.
struct CloudBadge: View {
    let badge: DriveDownloads.Badge

    var body: some View {
        content
            .font(.caption2.weight(.bold))
            .frame(width: 14, height: 14)
            .padding(6)
            .ptGlass(in: Circle())
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch badge {
        case .available:
            Image(systemName: "icloud.and.arrow.down")
        case let .downloading(fraction):
            ZStack {
                if let fraction {
                    Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.04, fraction))
                        .stroke(Color.ptAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "arrow.down").font(.system(size: 7, weight: .heavy))
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var label: String {
        switch badge {
        case .available: return "In Google Drive, not downloaded"
        case let .downloading(fraction): return fraction.map { "Downloading, \(Int(($0 * 100).rounded())) percent" } ?? "Downloading"
        case .failed: return "Download failed"
        }
    }
}

/// The cover grid shared by the library and search.
struct BookGrid: View {
    let books: [Book]
    /// Set in select mode: taps tick books instead of opening them.
    var selection: Binding<Set<UUID>>?
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    private let downloads = DriveDownloads.shared
    /// Starting over throws the place away, so it asks first.
    @State private var restarting: Book?
    /// Back to "want to read" forgets the place too, so it asks first.
    @State private var wantToRead: Book?
    /// Removing a local file removes the book with it, so it asks first.
    @State private var clearing: Book?

    /// Wider cells at accessibility sizes, so titles under the covers have room.
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)]
            : [GridItem(.adaptive(minimum: 108, maximum: 168), spacing: 18)]
    }

    var body: some View {
        let textVersions = library.pdfsWithTextVersions
        return LazyVGrid(columns: columns, spacing: 24) {
            ForEach(books) { book in
                Button {
                    if let selection {
                        if selection.wrappedValue.contains(book.id) { selection.wrappedValue.remove(book.id) }
                        else { selection.wrappedValue.insert(book.id) }
                    } else {
                        router.open(book, library: library)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        BookCoverView(
                            book: book, cover: library.coverThumbnail(for: book, maxPixels: 640),
                            selected: selection.map { $0.wrappedValue.contains(book.id) },
                            missing: library.missing.contains(book.id),
                            cloud: downloads.badge(for: book.id, inCloud: library.inCloud.contains(book.id)),
                            hasTextVersion: textVersions.contains(book.id))
                        Text(book.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        if !book.author.isEmpty {
                            Text(book.author)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: book))
                .accessibilityAddTraits(selection?.wrappedValue.contains(book.id) == true ? .isSelected : [])
                .accessibilityHint(selection == nil ? (library.inCloud.contains(book.id) ? "Opens the book’s page, where it can be downloaded" : "Opens the book")
                    : (selection?.wrappedValue.contains(book.id) == true ? "Double tap to deselect" : "Double tap to select"))
                .contextMenu {
                    // no menu while ticking books
                    if selection == nil {
                        if library.inCloud.contains(book.id) {
                            if downloads.isRunning(book.id) {
                                Button { downloads.cancel(book.id) } label: {
                                    Label("Cancel Download", systemImage: "xmark.circle")
                                }
                            } else {
                                Button { downloads.start(book, library: library) } label: {
                                    Label("Download", systemImage: "icloud.and.arrow.down")
                                }
                            }
                        } else {
                            Button { router.open(book, library: library) } label: {
                                Label(book.isAudio ? "Play" : "Read", systemImage: book.isAudio ? "play.fill" : "book.fill")
                            }
                        }
                        if (book.progression ?? 0) < 0.995 {
                            Button { router.markFinished(book, library: library) } label: {
                                Label(book.isAudio ? "Mark as Listened" : "Mark as Finished", systemImage: "checkmark.circle")
                            }
                        }
                        if (book.progression ?? 0) > 0 {
                            Button { restarting = book } label: {
                                Label(book.isAudio ? "Listen from the Beginning" : "Start from the Beginning", systemImage: "arrow.counterclockwise")
                            }
                        }
                        if BookMaster.shared.isLinked {
                            if book.bmStatus != BMShelfStatus.wantToRead.rawValue {
                                Button {
                                    if (book.progression ?? 0) > 0.001 { wantToRead = book }
                                    else { BookMaster.shared.moveToShelf(.wantToRead, bookID: book.id, library: library) }
                                } label: {
                                    Label("Move to Want to Read", systemImage: "bookmark")
                                }
                            }
                            if book.bmStatus != BMShelfStatus.abandoned.rawValue {
                                Button { BookMaster.shared.moveToShelf(.abandoned, bookID: book.id, library: library) } label: {
                                    Label("Mark as Abandoned", systemImage: "pause.circle")
                                }
                            }
                        }
                        Divider()
                        Button { router.detail = book } label: {
                            Label("Book Info", systemImage: "info.circle")
                        }
                        Button { router.openShelves([book.id]) } label: {
                            Label("Shelves…", systemImage: "books.vertical")
                        }
                        Button { router.editing = book } label: {
                            Label("Edit Details", systemImage: "pencil")
                        }
                        Divider()
                        if book.drive != nil, !library.inCloud.contains(book.id) {
                            Button { router.removeDownload(book, library: library) } label: {
                                Label("Remove Download", systemImage: "icloud.and.arrow.up")
                            }
                        }
                        if book.drive == nil, (book.progression ?? 0) >= 0.995, !library.missing.contains(book.id) {
                            Button { clearing = book } label: {
                                Label("Remove File", systemImage: "doc.badge.minus")
                            }
                        }
                        Button(role: .destructive) { router.askDelete([book]) } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    }
                }
            }
        }
        // filtering, sorting, adding and removing glide; ticking a book in select mode eases
        .ptAnimation(.smooth(duration: 0.35), value: books.map(\.id))
        .ptAnimation(.snappy(duration: 0.2), value: selection?.wrappedValue)
        .sensoryFeedback(.selection, trigger: selection?.wrappedValue)
        .confirmationDialog(
            "Start over?", isPresented: Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } }),
            titleVisibility: .visible, presenting: restarting
        ) { book in
            Button(book.isAudio ? "Listen from the Beginning" : "Start from the Beginning", role: .destructive) {
                library.restart(book.id)
            }
        } message: { _ in
            Text("Your place in this book is forgotten.")
        }
        .confirmationDialog(
            "Back to Want to Read?", isPresented: Binding(get: { wantToRead != nil }, set: { if !$0 { wantToRead = nil } }),
            titleVisibility: .visible, presenting: wantToRead
        ) { book in
            Button("Move to Want to Read", role: .destructive) {
                BookMaster.shared.moveToShelf(.wantToRead, bookID: book.id, library: library)
            }
        } message: { _ in
            Text("Your place in this book is forgotten.")
        }
        .confirmationDialog(
            "Remove the file of “\(clearing?.title ?? "")”?",
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            titleVisibility: .visible, presenting: clearing
        ) { book in
            Button("Remove File", role: .destructive) { router.clearFinished(book, library: library) }
        } message: { _ in
            Text("The file is the book’s only copy — the book is removed from the library with it. Your BookMaster shelf isn’t touched.")
        }
    }

    private func accessibilityLabel(for book: Book) -> String {
        var parts = [book.title]
        if !book.author.isEmpty { parts.append("by \(book.author)") }
        if book.isAudio { parts.append("audiobook") }
        if let p = book.progression, p > 0 { parts.append("\(Int((p * 100).rounded())) percent") }
        if library.missing.contains(book.id) { parts.append("file missing") }
        if library.inCloud.contains(book.id) { parts.append("in Google Drive, not downloaded") }
        return parts.joined(separator: ", ")
    }
}
