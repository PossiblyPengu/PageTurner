import SwiftUI

/// What removing a book can mean, said the same wherever it is asked.
enum BookRemoval {
    /// A Drive book that is on the phone can lose just its download and stay in the library.
    static func keepsBook(_ book: Book, inCloud: Set<UUID>) -> Bool {
        book.drive != nil && !inCloud.contains(book.id)
    }

    static func message(_ books: [Book], inCloud: Set<UUID>) -> String {
        if books.count == 1, let book = books.first, keepsBook(book, inCloud: inCloud) {
            return "Removing the download frees the space and keeps the book, your place and notes, to download again. Removing it from the library takes it all. Your BookMaster shelf isn’t touched."
        }
        return "This also deletes the file from this device. Your BookMaster shelf isn’t touched."
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
            if BookRemoval.keepsBook(book, inCloud: library.inCloud) {
                Button("Remove Download, Keep the Book") { router.removeDownload(book, library: library) }
            }
            Button("Remove from Library", role: .destructive) {
                router.putAway(book.id)
                library.delete(book)
            }
        } message: {
            Text(BookRemoval.message([book], inCloud: library.inCloud))
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
