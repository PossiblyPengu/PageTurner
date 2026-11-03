import SwiftUI

/// The books already asked about since they were last finished: the "you finished it" sheet comes once per finish —
/// not each time a finished book is left again — and a book started over may be asked about when it is finished
/// again (`forget`, from `LibraryStore.restart` and an audiobook played again from its end).
enum FinishedAsk {
    private static let key = "finished-asked"

    static func asked(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static func mark(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        // a library's worth is plenty: the oldest asks fall off first
        UserDefaults.standard.set(Array(ids.suffix(2000)), forKey: key)
    }

    static func forget(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard let at = ids.firstIndex(of: id.uuidString) else { return }
        ids.remove(at: at)
        UserDefaults.standard.set(ids, forKey: key)
    }
}

/// "You finished it": a rating for BookMaster, and what becomes of the book's file — the download given back (a
/// Drive book stays in the library, to come down again), the book and its file removed (the file is its only copy),
/// or kept. Asked once when a book is finished: on leaving the reader at its end, when an audiobook plays out, or
/// after Mark as Finished.
struct FinishedBookSheet: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Int?
    @State private var confirmRemove = false

    /// The book as the library holds it now (a rating just given, the file just removed).
    private var current: Book { library.books.first { $0.id == book.id } ?? book }

    static func canRate(_ book: Book) -> Bool {
        BookMaster.shared.isLinked && BookMaster.shared.syncEnabled
    }

    /// The book's files are on this iPhone, so there is space to give back.
    static func hasFiles(_ book: Book, library: LibraryStore) -> Bool {
        !library.missing.contains(book.id) && library.finishedBytes(of: book) != nil
    }

    /// Anything to ask at all: with nothing to rate and no file to free, the sheet would only say "well done".
    static func worthAsking(_ book: Book, library: LibraryStore) -> Bool {
        canRate(book) || hasFiles(book, library: library)
    }

    private var size: String? {
        library.finishedBytes(of: current).map { AutoBackup.sizeText($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if Self.canRate(current) { rating }
                    if Self.hasFiles(current, library: library) { fileChoices }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Remove “\(current.title)”?", isPresented: $confirmRemove, titleVisibility: .visible
            ) {
                Button("Remove Book and File", role: .destructive) {
                    router.clearFinished(current, library: library)
                    dismiss()
                }
            } message: {
                Text("The file is the book’s only copy — the book is removed from the library with it. Your BookMaster shelf isn’t touched.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let cover = library.coverThumbnail(for: current, maxPixels: 360) {
                    Image(uiImage: cover).resizable().scaledToFit()
                } else {
                    Image(systemName: current.isAudio ? "headphones" : "book.closed.fill")
                        .font(.largeTitle)
                        .frame(width: 80, height: 120)
                        .background(Color.ptAccent.opacity(0.2))
                }
            }
            .frame(maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            Text(current.isAudio ? "You finished listening to" : "You finished")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(current.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if !current.author.isEmpty {
                Text(current.author).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rating: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(1 ... 5, id: \.self) { n in
                    Button {
                        picked = n
                        library.rate(current.id, stars: n)
                    } label: {
                        Image(systemName: n <= (picked ?? current.bmRating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(Color.ptAccent)
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(n == 1 ? "1 star" : "\(n) stars")
                    .accessibilityAddTraits(n == (picked ?? current.bmRating ?? 0) ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: picked)
            Text("Your rating goes to BookMaster.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fileChoices: some View {
        VStack(spacing: 10) {
            if current.drive != nil {
                Button {
                    router.removeDownload(current, library: library)
                    dismiss()
                } label: {
                    Label(size.map { "Remove Download (\($0))" } ?? "Remove Download", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("The book stays in your library, with your place and notes, and can be downloaded again from Google Drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(size.map { "Remove Book and File (\($0))" } ?? "Remove Book and File", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                dismiss()
            } label: {
                Text("Keep It").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 6)
    }
}
