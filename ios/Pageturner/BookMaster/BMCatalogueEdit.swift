import Foundation

/// A book's details edited in Pageturner, carried on to BookMaster. The catalogue row there is one shared entry per
/// title (an edit corrects it for both readers, as it does when made on BookMaster's own book page), and the bridge's
/// `edit-book` writes the whole row: a field left out is cleared, the genres and the cover link among them. So what
/// is sent is made from two things — what the reader changed here (`changes`), and the row as it stands there now
/// (`merged`) — and a field they did not touch keeps BookMaster's own value, which may have been edited there since.
///
/// What Edit Details holds that BookMaster's page has no place for — the description, the series — stays here.
/// Pure, so it is checked on Linux.
enum BMCatalogueEdit {
    /// The bridge's names for the facts both sides hold.
    static let keys = ["title", "author", "total_pages", "published_year", "isbn"]

    /// What the reader changed between `before` (the book as Edit Details opened) and `after`, in the bridge's terms;
    /// an empty answer means nothing BookMaster holds changed. A cleared pages, year or ISBN is `NSNull` — clearing
    /// it there too. A title or author cannot be cleared (BookMaster needs both), a year that is not a number cannot
    /// be sent, and an author is sent in display order (`sendableAuthor`).
    static func changes(from before: Book, to after: Book) -> [String: Any] {
        var out: [String: Any] = [:]
        let title = after.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != before.title.trimmingCharacters(in: .whitespaces) { out["title"] = title }
        let author = sendableAuthor(after.author).trimmingCharacters(in: .whitespaces)
        if !author.isEmpty, author != sendableAuthor(before.author).trimmingCharacters(in: .whitespaces) {
            out["author"] = author
        }
        if after.pages != before.pages {
            if let pages = after.pages, pages > 0 { out["total_pages"] = pages } else if after.pages == nil { out["total_pages"] = NSNull() }
        }
        if (after.year ?? "") != (before.year ?? "") {
            let text = (after.year ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                out["published_year"] = NSNull()
            } else if let year = Int(text), (1...3000).contains(year) {
                out["published_year"] = year
            }
        }
        if after.isbn != before.isbn { out["isbn"] = after.isbn ?? NSNull() }
        return out
    }

    /// The `edit-book` body for `changes` laid over the catalogue row as BookMaster has it now (`catalogue` from the
    /// `book` route): the changed facts, the row's own for the rest, and its genres and cover link sent back as they
    /// are so the write does not clear them. Nil when the row has no title or author to send.
    static func merged(_ changes: [String: Any], onto catalogue: [String: Any]) -> [String: Any]? {
        guard let bookID = catalogue["id"] as? String, !bookID.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            let value = ((changes[key] as? String) ?? (catalogue[key] as? String))?.trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }
        func number(_ key: String) -> Any {
            let value = changes.keys.contains(key) ? changes[key] : catalogue[key]
            if let n = value as? Int, n > 0 { return n }
            if let d = value as? Double, d.isFinite, d >= 1 { return Int(d) }
            return NSNull()
        }
        guard let title = text("title"), let author = text("author") else { return nil }
        var isbn: Any = NSNull()
        if changes.keys.contains("isbn") {
            if let s = changes["isbn"] as? String, !s.isEmpty { isbn = s }
        } else if let s = catalogue["isbn"] as? String, !s.isEmpty {
            isbn = s
        }
        return [
            "book_id": bookID,
            "title": title,
            "author": author,
            "total_pages": number("total_pages"),
            "published_year": number("published_year"),
            "isbn": isbn,
            "genres": genres(catalogue["genres"]),
            "cover_url": coverLink(catalogue["cover_url"]),
        ]
    }

    /// The row's genres: stored as JSON text, and read here whether it comes as that or as a list.
    static func genres(_ raw: Any?) -> [String] {
        var list: [Any] = []
        if let array = raw as? [Any] {
            list = array
        } else if let text = raw as? String, let data = text.data(using: .utf8),
                  let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            list = array
        }
        return Array(list.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(10))
    }

    /// The cover link to send back so the write leaves the cover as it is: a provider's `https` link as it is (an
    /// `http` one upgraded — the bridge refuses any other), nothing for none. BookMaster keeps a jacket this app
    /// pushed (`/api/covers/…`) by itself when the edit does not pick a new one, whatever is sent for it.
    static func coverLink(_ raw: Any?) -> Any {
        guard let url = (raw as? String)?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return NSNull() }
        if url.hasPrefix("https://") { return url }
        if url.hasPrefix("http://") { return "https://" + url.dropFirst("http://".count) }
        return NSNull()
    }

    // MARK: Parked edits

    /// Two parked edits are for the same shelf row.
    static func sameRow(_ left: Data, _ right: Data) -> Bool {
        guard let a = (try? JSONSerialization.jsonObject(with: left)) as? [String: Any],
              let b = (try? JSONSerialization.jsonObject(with: right)) as? [String: Any],
              let x = a["user_book_id"] as? String, let y = b["user_book_id"] as? String else { return false }
        return x == y && (a["username"] as? String) == (b["username"] as? String)
    }

    /// An edit parked while offline, then another to the same row: one edit, the later change winning field by field.
    static func merging(older: Data, newer: Data) -> Data {
        guard var fresh = (try? JSONSerialization.jsonObject(with: newer)) as? [String: Any],
              let before = (try? JSONSerialization.jsonObject(with: older)) as? [String: Any]
        else { return newer }
        var set = (before["set"] as? [String: Any]) ?? [:]
        for (key, value) in (fresh["set"] as? [String: Any]) ?? [:] { set[key] = value }
        fresh["set"] = set
        return (try? JSONSerialization.data(withJSONObject: fresh)) ?? newer
    }
}
