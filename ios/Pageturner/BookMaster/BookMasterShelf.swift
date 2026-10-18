import Foundation

/// One row of the reader's BookMaster shelf. The shelf is kept on the phone (`BookMaster.shelfRows`), so
/// every field the screens use is optional: a row cached by an older build still reads.
struct BMShelfRow: Codable, Hashable, Identifiable {
    var userBookId: String
    var bookId: String
    var title: String
    var author: String?
    var status: String
    var rating: Int?
    var upNext: Int?
    var percent: Double?
    var format: String?
    var totalPages: Int?
    var openLibraryId: String?
    var isbn: String?
    /// Catalogue facts the bridge shares so this device can fill what its own
    /// file never said — a year, a blurb, the jacket.
    var publishedYear: Int?
    var description: String?
    /// The cover BookMaster actually serves for the row, already absolute —
    /// including jackets this app pushed up (`/api/covers/…`).
    var coverUrl: String?
    /// When it was finished, and when the row last moved — the "recently
    /// finished" list a member card draws.
    var finishDate: String?
    var updatedAt: String?

    var id: String { userBookId }
    var isAudio: Bool { format == "audio" }

    /// A jacket for the row: the stored cover when BookMaster knows one, else
    /// Open Library's guess by ISBN or work id.
    var coverURL: URL? {
        if let coverUrl, let url = URL(string: coverUrl) { return url }
        let digits = (isbn ?? "").filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if digits.count >= 10 { return URL(string: "https://covers.openlibrary.org/b/isbn/\(digits)-M.jpg?default=false") }
        if let ol = openLibraryId, !ol.isEmpty { return URL(string: "https://covers.openlibrary.org/b/olid/\(ol)-M.jpg?default=false") }
        return nil
    }
}

private struct BMShelfReply: Decodable { var books: [BMShelfRow] }

/// Which shelf row a local book is — the ladder the push side runs, mirrored
/// from `docs/js/bm-pull.js`: the pin, then a folded title + author match.
enum BMShelf {
    private static func fold(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func stripBrackets(_ s: String) -> String {
        var out = s
        for (open, close) in [("(", ")"), ("[", "]")] as [(Character, Character)] {
            while let a = out.firstIndex(of: open), let b = out[a...].firstIndex(of: close) {
                out.replaceSubrange(a...b, with: " ")
            }
        }
        return out
    }

    /// The shapes a file's title can take: itself, the series note stripped
    /// ("Dune (Dune Chronicles, #1)" files as "Dune"), and the part ahead of a
    /// subtitle marker.
    static func titleForms(_ s: String) -> Set<String> {
        if let hit = formsMemo.get(s) { return hit }
        let forms = computeTitleForms(s)
        formsMemo.set(s, forms)
        return forms
    }

    /// `titleForms` is pure and `match` asks for the same few thousand titles over and over (every
    /// book against every row), so the answers are remembered. Capped so it cannot grow without end.
    private final class FormsMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: Set<String>] = [:]

        func get(_ key: String) -> Set<String>? {
            lock.lock(); defer { lock.unlock() }
            return table[key]
        }

        func set(_ key: String, _ value: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            if table.count >= 8_000 { table.removeAll(keepingCapacity: true) }
            table[key] = value
        }
    }

    private static let formsMemo = FormsMemo()

    private static func computeTitleForms(_ s: String) -> Set<String> {
        var forms: Set<String> = [fold(s), fold(stripBrackets(s))]
        func head(_ t: String) -> String {
            var h = t
            for marker in [" — ", " – ", ": ", " - "] {
                if let r = h.range(of: marker) { h = String(h[..<r.lowerBound]) }
            }
            return h
        }
        forms.insert(fold(head(s)))
        forms.insert(fold(head(stripBrackets(s))))
        forms.remove("")
        return forms
    }

    static func titlesAgree(_ want: String, _ got: String) -> Bool {
        let ws = titleForms(want)
        return titleForms(got).contains { g in
            ws.contains { w in
                w == g
                    || (w.count >= 8 && g.hasPrefix(w + " "))
                    || (g.count >= 8 && w.hasPrefix(g + " "))
            }
        }
    }

    /// First initial + surname, so "Herbert, Frank" and "Frank Herbert (Author)" agree.
    private static func nameKey(_ s: String) -> String? {
        let parts = fold(stripBrackets(s)).split(separator: " ").map(String.init)
        guard let first = parts.first, let last = parts.last else { return nil }
        return "\(first.prefix(1)) \(last)"
    }

    static func authorsAgree(_ want: String, _ got: String?) -> Bool {
        guard !want.isEmpty, let got, !got.isEmpty else { return true } // a missing author never decides
        let gotKeys = Set(
            got.replacingOccurrences(of: " and ", with: ";")
                .replacingOccurrences(of: "&", with: ";")
                .split(separator: ";").compactMap { nameKey(String($0)) })
        let wanted = sendableAuthor(want)
        return gotKeys.contains(nameKey(wanted) ?? "") || gotKeys.contains(nameKey(want) ?? "")
    }

    static func match(_ book: Book, in rows: [BMShelfRow]) -> BMShelfRow? {
        if let pin = book.bookmasterId, let hit = rows.first(where: { $0.userBookId == pin }) {
            return hit
        }
        if let id = book.openLibraryId, !id.isEmpty,
           let hit = rows.first(where: { $0.openLibraryId == id }) { return hit }
        if let raw = book.isbn, let isbn = ISBN.canonical(raw),
           let hit = rows.first(where: { $0.isbn.flatMap(ISBN.canonical) == isbn }) { return hit }
        return rows.first { titlesAgree(book.title, $0.title) && authorsAgree(book.author, $0.author) }
    }
}

/// The shelf as the Shelf screen shows it: what BookMaster has that this iPhone has no file for.
extension BMShelf {
    struct Group: Identifiable, Equatable {
        var title: String
        var rows: [BMShelfRow]
        var id: String { title }
    }

    static func label(forStatus status: String) -> String {
        switch status {
        case "reading": return "Reading"
        case "read": return "Read"
        case "want_to_read": return "Want to read"
        case "dnf", "abandoned": return "Abandoned"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The rows no book in `books` is — by the pin, then by title and author, as `match` does.
    static func missing(from rows: [BMShelfRow], on books: [Book]) -> [BMShelfRow] {
        rows.filter { row in !books.contains { match($0, in: [row]) != nil } }
    }

    /// Up next first (in its own order), then what is being read, wanted and finished, then anything else.
    static func groups(_ rows: [BMShelfRow]) -> [Group] {
        let queued = rows.filter { $0.upNext != nil }.sorted { ($0.upNext ?? 0) < ($1.upNext ?? 0) }
        let rest = rows.filter { $0.upNext == nil }
        let known: Set<String> = ["reading", "want_to_read", "read"]
        let all: [Group] = [
            Group(title: "Up next", rows: queued),
            Group(title: "Reading", rows: rest.filter { $0.status == "reading" }),
            Group(title: "Want to read", rows: rest.filter { $0.status == "want_to_read" }),
            Group(title: "Finished", rows: rest.filter { $0.status == "read" }),
            Group(title: "Other", rows: rest.filter { !known.contains($0.status) }),
        ]
        return all.filter { !$0.rows.isEmpty }
    }
}

extension BookMaster {
    /// Decorate the library with what the shelf knows. Pageturner's own
    /// position stays the local truth — a remote percent is shown, never imposed.
    /// False when the shelf could not be fetched (offline, or a refusal) and the last copy stands.
    @discardableResult
    func pullShelf(into library: LibraryStore) async -> Bool {
        guard let user else { return false }
        guard let (data, status) = try? await get("library", query: ["username": user.username]),
              (200..<300).contains(status),
              let reply = try? JSONDecoder().decode(BMShelfReply.self, from: data),
              self.user?.username == user.username   // unlinked, or another reader linked, while it was out
        else { return false }
        keepShelf(reply.books)
        var changes: [(UUID, (inout Book) -> Void)] = []
        var covers: [(Book, URL)] = []
        for book in library.books {
            guard let row = BMShelf.match(book, in: reply.books) else {
                // gone from the shelf (removed on BookMaster): the badges, rating and Up next go with it
                if book.bmStatus != nil || book.bmRating != nil || book.bmRemotePercent != nil || book.bmUpNext != nil {
                    changes.append((book.id, { b in
                        b.bmStatus = nil
                        b.bmRating = nil
                        b.bmRemotePercent = nil
                        b.bmUpNext = nil
                    }))
                }
                continue
            }
            let shelf = (id: row.userBookId, status: row.status, rating: row.rating,
                         percent: row.percent, upNext: row.upNext != nil)
            changes.append((book.id, { b in
                // the matched row wins: a stale pin (deleted there, or left by
                // another reader) is replaced, a good one comes back unchanged
                b.bookmasterId = shelf.id
                b.bmStatus = shelf.status
                b.bmRating = shelf.rating
                b.bmRemotePercent = shelf.percent
                b.bmUpNext = shelf.upNext
                // catalogue facts fill gaps only — what this copy already
                // knows about itself is never rewritten from afar
                if b.isbn == nil { b.isbn = row.isbn }
                if b.openLibraryId == nil { b.openLibraryId = row.openLibraryId }
                if b.year == nil, let year = row.publishedYear { b.year = String(year) }
                if b.bookDescription == nil || b.bookDescription?.isEmpty == true {
                    if let blurb = row.description, !blurb.isEmpty { b.bookDescription = blurb }
                }
            }))
            if let url = row.coverURL,
               !FileManager.default.fileExists(atPath: library.coverURL(for: book).path),
               !Self.recentlyMissedCover(book.id) {
                covers.append((book, url))
            }
        }
        library.applyShelf(changes)
        // and the jackets: a book with none of its own takes BookMaster's
        // in the background: the refresh spinner should not wait on a string of image downloads
        if !covers.isEmpty {
            Task {
                for (book, url) in covers where !Task.isCancelled {
                    await MetadataLookup.applyCover(from: url, to: book, library: library)
                    if !FileManager.default.fileExists(atPath: library.coverURL(for: book).path) {
                        Self.noteCoverMiss(book.id)
                    }
                }
            }
        }
        return true
    }

    // A cover URL that gave nothing (a 404, not an image) is not asked again on every pull.
    private static let coverMissKey = "bm-cover-miss"
    private static let coverMissHours: Double = 6

    private static func recentlyMissedCover(_ id: UUID) -> Bool {
        let misses = UserDefaults.standard.dictionary(forKey: coverMissKey) as? [String: Double] ?? [:]
        guard let at = misses[id.uuidString] else { return false }
        return Date().timeIntervalSince1970 - at < coverMissHours * 3600
    }

    private static func noteCoverMiss(_ id: UUID) {
        var misses = UserDefaults.standard.dictionary(forKey: coverMissKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        misses = misses.filter { now - $0.value < coverMissHours * 3600 }   // old entries expire
        misses[id.uuidString] = now
        UserDefaults.standard.set(misses, forKey: coverMissKey)
    }
}
