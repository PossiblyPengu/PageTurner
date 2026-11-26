import SwiftUI

/// What removing a book can mean, said the same wherever it is asked.
enum BookRemoval {
    /// The book's files are on this iPhone, so they can go and the book stay: a Drive book to be downloaded again, any
    /// other to be given its file back from Files.
    static func canRemoveFile(_ book: Book, inCloud: Set<UUID>, missing: Set<UUID>) -> Bool {
        !inCloud.contains(book.id) && !missing.contains(book.id)
    }

    static func removeFileLabel(_ book: Book) -> String {
        book.drive != nil ? "Remove Download, Keep the Book" : "Remove File, Keep the Book"
    }

    static func message(_ books: [Book], inCloud: Set<UUID>, missing: Set<UUID> = []) -> String {
        let withFiles = books.filter { canRemoveFile($0, inCloud: inCloud, missing: missing) }
        if books.count == 1, let book = withFiles.first {
            return book.drive != nil
                ? "Removing the download frees the space and keeps the book, your place and notes, to download again. Removing it from the library takes it all. Your BookMaster shelf isn’t touched."
                : "Removing the file frees the space and keeps the book — your place, highlights and notes — to read again when you give it the file back. Removing it from the library takes it all. Your BookMaster shelf isn’t touched."
        }
        // a book whose file has gone has none to delete
        if withFiles.isEmpty {
            return books.count == 1
                ? "Its place, highlights and notes go with it. Your BookMaster shelf isn’t touched."
                : "Their places, highlights and notes go with them. Your BookMaster shelf isn’t touched."
        }
        return "Removing the files frees the space and keeps the books, with your places and notes. Removing them from the library takes it all, files included. Your BookMaster shelf isn’t touched."
    }
}

/// "Remove …?" for one book, belonging to the view it was asked from — a cover, Book Info's row. iOS 26 draws a dialog
/// over the view it belongs to, and the one that belonged to the whole screen floated over some other book.
struct RemoveBookDialog: ViewModifier {
    let book: Book
    @Binding var isPresented: Bool
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.confirmationDialog("Remove “\(book.title)”?", isPresented: $isPresented, titleVisibility: .visible) {
            if BookRemoval.canRemoveFile(book, inCloud: library.inCloud, missing: library.missing) {
                Button(BookRemoval.removeFileLabel(book)) { router.removeFile(book, library: library) }
            }
            Button("Remove from Library", role: .destructive) { router.remove([book], library: library) }
        } message: {
            Text(BookRemoval.message([book], inCloud: library.inCloud, missing: library.missing))
        }
    }
}

/// A cover's own dialogs — starting over, back to want to read, removing — each shown over that cover. The grid keeps
/// which book is being asked about; every cover answers only for itself.
struct BookCellDialogs: ViewModifier {
    let book: Book
    @Binding var restarting: Book?
    @Binding var wantToRead: Book?
    @Binding var removing: Book?
    @EnvironmentObject private var library: LibraryStore

    private func asking(_ state: Binding<Book?>) -> Binding<Bool> {
        let id = book.id
        return Binding(get: { state.wrappedValue?.id == id }, set: { if !$0 { state.wrappedValue = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Start over?", isPresented: asking($restarting), titleVisibility: .visible) {
                Button(book.isAudio ? "Listen from the Beginning" : "Start from the Beginning", role: .destructive) {
                    library.restart(book.id)
                }
            } message: {
                Text("Your place in this book is forgotten.")
            }
            .confirmationDialog("Back to Want to Read?", isPresented: asking($wantToRead), titleVisibility: .visible) {
                Button("Move to Want to Read", role: .destructive) {
                    BookMaster.shared.moveToShelf(.wantToRead, bookID: book.id, library: library)
                }
            } message: {
                Text("Your place in this book is forgotten.")
            }
            .modifier(RemoveBookDialog(book: book, isPresented: asking($removing)))
    }
}

/// "Removed “Dune” · Undo" at the top of the app for a few seconds after a removal (`LibraryStore.undoable`); when it
/// goes, what was set aside is deleted. It is laid over the whole shell, so it is seen wherever the removal was made —
/// a cover, Book Info, the select bar, the finish sheet.
struct RemovalUndoHost: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Group {
            if let removal = library.undoable {
                HStack(spacing: 12) {
                    Image(systemName: removal.fileOnly ? "doc" : "trash")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(removal.line)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Undo") { library.undoRemoval() }
                        .font(.subheadline.weight(.semibold))
                        .tint(.ptAccent)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .ptGlass(in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .id(removal.id)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: removal.id) {
                    AccessibilityNotification.Announcement("\(removal.line). Undo is available.").post()
                    guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
                    if library.undoable?.id == removal.id { library.finishRemoval() }
                }
            }
        }
        .ptAnimation(.smooth(duration: 0.3), value: library.undoable?.id)
    }
}
