import UIKit

extension BookMaster {
    private static let sentKey = "bm-covers-sent"

    /// A jacket the reader has just chosen for a book (from the photos, a search, a drawn crop): sent again. A cover is
    /// otherwise sent once, so a changed one never reached BookMaster, where the new push replaces the old.
    func coverChosen(_ id: UUID, library: LibraryStore) {
        var sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
        guard sent.remove(id.uuidString) != nil else { return }   // never sent: it goes with the next batch as it is
        UserDefaults.standard.set(Array(sent), forKey: Self.sentKey)
        Task { await pushCovers(from: library) }
    }

    /// Send the jackets of the library's books that are pinned to a shelf row, once each, so BookMaster's
    /// shelf shows the cover of the copy read here. BookMaster keeps its own art where it has better.
    func pushCovers(from library: LibraryStore) async {
        guard isLinked, syncEnabled, AppPrefs.sendCovers else { return }
        var sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
        var unsaved = 0
        // written in batches, and on every way out, instead of once per cover
        func save() {
            guard unsaved > 0 else { return }
            UserDefaults.standard.set(Array(sent), forKey: Self.sentKey)
            unsaved = 0
        }
        defer { save() }
        for book in library.books where book.bookmasterId != nil && !sent.contains(book.id.uuidString) {
            guard !Task.isCancelled, isLinked else { return }
            // ImageIO decodes straight to 400px (and caches it): no full-size decode on the main actor
            guard let image = library.coverThumbnail(for: book, maxPixels: 400),
                  let jpeg = image.jpegData(compressionQuality: 0.8) else { continue }
            if await pushCover(ref: book.bookMasterRef, jpeg: jpeg) {
                sent.insert(book.id.uuidString)
                unsaved += 1
                if unsaved >= 10 { save() }
            }
        }
    }
}
