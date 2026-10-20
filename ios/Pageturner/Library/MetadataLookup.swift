import Foundation
import UIKit

/// One possible match from an online metadata source.
struct MetadataCandidate: Identifiable, Hashable, Codable {
    let id = UUID()
    var title: String
    var authors: String
    var year: String
    /// A blurb, when the source has one.
    var summary: String = ""
    var isbn: String?
    /// Open Library work id — what BookMaster keeps on its catalogue rows.
    var openLibraryId: String?
    /// Jacket guesses, best first: the source's own cover, then Open Library's
    /// by ISBN and work id. `CoverFetch` walks the list until a real image
    /// answers, so a 404 on the first guess is not the end.
    var coverURLs: [URL] = []
    var coverURL: URL? { coverURLs.first }
    var source: String
    /// The BookMaster shelf row this is — applying it pins the book there, so a
    /// later push can never write a duplicate.
    var bookmasterId: String?

    /// `id` is only for the list on screen; what is kept on disk is the rest.
    /// `coverURL` is read for lists cached by older builds, which kept one.
    enum CodingKeys: String, CodingKey {
        case title, authors, year, summary, isbn, openLibraryId, coverURL, coverURLs, source, bookmasterId
    }
}

extension MetadataCandidate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        authors = try c.decode(String.self, forKey: .authors)
        year = try c.decode(String.self, forKey: .year)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        openLibraryId = try c.decodeIfPresent(String.self, forKey: .openLibraryId)
        if let urls = try c.decodeIfPresent([URL].self, forKey: .coverURLs) {
            coverURLs = urls
        } else if let url = try c.decodeIfPresent(URL.self, forKey: .coverURL) {
            coverURLs = [url]
        }
        source = try c.decode(String.self, forKey: .source)
        bookmasterId = try c.decodeIfPresent(String.self, forKey: .bookmasterId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encode(year, forKey: .year)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(isbn, forKey: .isbn)
        try c.encodeIfPresent(openLibraryId, forKey: .openLibraryId)
        try c.encode(coverURLs, forKey: .coverURLs)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(bookmasterId, forKey: .bookmasterId)
    }
}

/// Book metadata lookup: BookMaster's own catalogue first when linked (its hits
/// carry shelf pins and catalogue ids), then Google Books and Open Library.
/// Only ever called on an explicit user action — the edit sheet's "Find Details"
/// or a bulk "Find details" on selected books — never in the background.
enum MetadataLookup {
    /// Short timeouts: a source that is down or slow (Open Library often is) must not hold up the others.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Searches already made, by what was asked: kept in the caches folder for two weeks, so a book looked up once is
    /// never asked of the network again (and a library re-matched after a restore is quick).
    private struct Remembered: Codable {
        var at: Date
        var list: [MetadataCandidate]
    }
    @MainActor private static var remembered: [String: Remembered] = loadRemembered()
    private static let rememberedLimit = 200

    private static var rememberedFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("metadata-lookup.json")
    }

    private static func loadRemembered() -> [String: Remembered] {
        guard let data = try? Data(contentsOf: rememberedFile),
              let saved = try? JSONDecoder().decode([String: Remembered].self, from: data)
        else { return [:] }
        let fresh = Date().addingTimeInterval(-14 * 86_400)
        return saved.filter { $0.value.at > fresh }
    }

    @MainActor private static func recalled(_ key: String) -> [MetadataCandidate]? {
        guard let hit = remembered[key], hit.at > Date().addingTimeInterval(-14 * 86_400) else { return nil }
        return hit.list
    }

    @MainActor private static func remember(_ key: String, _ list: [MetadataCandidate]) {
        remembered[key] = Remembered(at: Date(), list: list)
        if remembered.count > rememberedLimit {
            for old in remembered.sorted(by: { $0.value.at < $1.value.at }).prefix(remembered.count - rememberedLimit) {
                remembered[old.key] = nil
            }
        }
        if let data = try? JSONEncoder().encode(remembered) { try? data.write(to: rememberedFile, options: .atomic) }
    }

    /// All sources at once. `progress` hears the merged list each time one answers (the fastest shows at once, the
    /// slowest only adds); `stopWhen` ends the search early once the list so far holds what the caller wanted.
    static func search(
        title: String, author: String, isbn: String? = nil,
        progress: (@MainActor ([MetadataCandidate]) -> Void)? = nil,
        stopWhen: (([MetadataCandidate]) -> Bool)? = nil
    ) async -> [MetadataCandidate] {
        let key = (title + "|" + author + "|" + (isbn ?? "")).lowercased()
        if let hit = await MainActor.run(body: { recalled(key) }) {
            await progress?(hit)
            return hit
        }
        // a name with the author in it ("David Wong - John Dies at the End") is asked as it stands, as title and
        // author, and the other way round: files are named either way
        var asks: [(title: String, author: String)] = [(title, author)]
        if author.isEmpty {
            let (left, right) = splitName(title)
            if !right.isEmpty { asks += [(left, right), (right, left)] }
        }
        // an ISBN names the book outright: asked of the two sources that take one, beside the title and author
        let extra = isbn.flatMap { ISBN.normalize($0) }
        var slots: [[MetadataCandidate]] = Array(repeating: [], count: asks.count * 3 + (extra == nil ? 0 : 2))
        var finished = 0
        var stopped = false
        await withTaskGroup(of: (Int, [MetadataCandidate]).self) { group in
            for (n, ask) in asks.enumerated() {
                group.addTask { (n * 3, await bookMasterCandidates(title: ask.title, author: ask.author)) }
                group.addTask { (n * 3 + 1, await googleBooks(title: ask.title, author: ask.author)) }
                group.addTask { (n * 3 + 2, await openLibrary(title: ask.title, author: ask.author)) }
            }
            if let extra {
                group.addTask { (asks.count * 3, await googleBooks(query: "isbn:\(extra)")) }
                group.addTask { (asks.count * 3 + 1, await openLibrary(items: [URLQueryItem(name: "isbn", value: extra)])) }
            }
            for await (index, list) in group {
                slots[index] = list
                finished += 1
                let merged = dedupe(slots.flatMap { $0 })
                await progress?(merged)
                if let stopWhen, stopWhen(merged) {
                    stopped = true
                    group.cancelAll()
                    break
                }
            }
        }
        let result = dedupe(slots.flatMap { $0 })
        // a search cut short, or one where nothing came back (the network, not the book), is not worth remembering
        if !stopped, !result.isEmpty {
            await MainActor.run { remember(key, result) }
        }
        return result
    }

    /// The same book from several sources collapses to one row — the first
    /// source's, with whatever it lacked (a blurb, an ISBN, a cover) filled in.
    static func dedupe(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var index: [String: Int] = [:]
        var out: [MetadataCandidate] = []
        for c in candidates {
            let key = (c.title + "|" + c.authors)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty else { continue }
            if let i = index[key] {
                if out[i].summary.isEmpty { out[i].summary = c.summary }
                if out[i].isbn == nil { out[i].isbn = c.isbn }
                if out[i].openLibraryId == nil { out[i].openLibraryId = c.openLibraryId }
                // merge cover guesses, keeping the survivor's own first
                out[i].coverURLs.append(contentsOf: c.coverURLs.filter { !out[i].coverURLs.contains($0) })
                if out[i].year.isEmpty { out[i].year = c.year }
                continue
            }
            index[key] = out.count
            out.append(c)
        }
        return out
    }

    // MARK: - BookMaster

    private static func bookMasterCandidates(title: String, author: String) async -> [MetadataCandidate] {
        let hits = await BookMaster.shared.searchCatalogue(title: title, author: author)
        return hits.compactMap { hit in
            guard !hit.title.isEmpty else { return nil }
            let isbn = hit.isbn.flatMap { ISBN.normalize($0) }
            var covers = hit.coverUrl.flatMap { URL(string: $0) }.map { [$0] } ?? []
            covers += CoverLinks.isbn(isbn) + CoverLinks.openLibraryWork(hit.openLibraryId)
            return MetadataCandidate(
                title: hit.title,
                authors: hit.author ?? "",
                year: hit.year ?? "",
                isbn: isbn,
                openLibraryId: hit.openLibraryId,
                coverURLs: covers,
                source: hit.userBookId != nil ? "On your BookMaster shelf" : "BookMaster",
                bookmasterId: hit.userBookId)
        }
    }

    // MARK: - Google Books

    private static func googleBooks(title: String, author: String) async -> [MetadataCandidate] {
        var q = "intitle:\(title)"
        if !author.isEmpty { q += " inauthor:\(author)" }
        return await googleBooks(query: q)
    }

    private static func googleBooks(query q: String) async -> [MetadataCandidate] {
        guard var comp = URLComponents(string: "https://www.googleapis.com/books/v1/volumes") else { return [] }
        comp.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "fields", value: "items(volumeInfo(title,authors,publishedDate,imageLinks,description,industryIdentifiers))"),
        ]
        guard let url = comp.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let info = item["volumeInfo"] as? [String: Any],
                  let t = info["title"] as? String, !t.isEmpty
            else { return nil }
            let authors = (info["authors"] as? [String] ?? []).joined(separator: ", ")
            let year = String((info["publishedDate"] as? String ?? "").prefix(4))
            var covers: [URL] = []
            if let links = info["imageLinks"] as? [String: Any],
               let thumb = (links["thumbnail"] as? String) ?? (links["smallThumbnail"] as? String),
               let url = URL(string: thumb.replacingOccurrences(of: "http://", with: "https://"))
            {
                // Google serves covers over http — force https for ATS
                covers.append(url)
            }
            let identifiers = (info["industryIdentifiers"] as? [[String: Any]] ?? [])
                .compactMap { $0["identifier"] as? String }
            let isbn = ISBN.best(of: identifiers)
            covers += CoverLinks.isbn(isbn)
            return MetadataCandidate(
                title: t, authors: authors, year: year,
                summary: BookText.plain(fromHTML: info["description"] as? String ?? ""),
                isbn: isbn, coverURLs: covers, source: "Google Books")
        }
    }

    // MARK: - Open Library

    private static func openLibrary(title: String, author: String) async -> [MetadataCandidate] {
        var items = [URLQueryItem(name: "title", value: title)]
        if !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        return await openLibrary(items: items)
    }

    private static func openLibrary(items asked: [URLQueryItem]) async -> [MetadataCandidate] {
        guard var comp = URLComponents(string: "https://openlibrary.org/search.json") else { return [] }
        comp.queryItems = asked + [
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i,isbn"),
        ]
        guard let url = comp.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]]
        else { return [] }

        return docs.compactMap { doc in
            guard let t = doc["title"] as? String, !t.isEmpty else { return nil }
            let authors = (doc["author_name"] as? [String] ?? []).joined(separator: ", ")
            let year = (doc["first_publish_year"] as? Int).map(String.init) ?? ""
            var covers: [URL] = []
            // cover_i is -1 when the work has no jacket — asking for it still
            // produced a URL, which is why dead cover boxes showed in results
            if let coverID = doc["cover_i"] as? Int {
                covers += CoverLinks.coverID(coverID)
            }
            // "/works/OL45804W" → "OL45804W", the id BookMaster keeps
            let olid = (doc["key"] as? String).map { $0.replacingOccurrences(of: "/works/", with: "") }
            let isbns = (doc["isbn"] as? [String] ?? []).prefix(25).map { $0 }
            let isbn = ISBN.best(of: Array(isbns))
            // an ISBN- or OLID-keyed jacket is a second guess when the work's
            // own cover id is missing or 404s
            covers += CoverLinks.isbn(isbn)
            return MetadataCandidate(
                title: t, authors: authors, year: year, isbn: isbn,
                openLibraryId: olid, coverURLs: covers, source: "Open Library")
        }
    }

    // MARK: - Applying

    /// Download a candidate's cover into the covers folder for `book`. `urls`
    /// is the fallback chain: the first that answers with a real image wins.
    static func applyCover(from urls: [URL], to book: Book, library: LibraryStore) async {
        guard let image = await CoverFetch.firstImage(in: urls),
              let jpeg = image.jpegData(compressionQuality: 0.85)
        else { return }
        await MainActor.run {
            do {
                try jpeg.write(to: library.coverURL(for: book))
                library.coverChanged()
            } catch {
                Log.error("metadata", "cover write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fill in what a book is missing from the first online match that really is
    /// the same book — used by bulk "Find details". Never overwrites something
    /// already there. Returns whether anything changed.
    @MainActor
    static func autoApply(to id: UUID, library: LibraryStore, title: String? = nil, author: String? = nil) async -> Bool {
        guard let book = library.books.first(where: { $0.id == id }) else { return false }
        let askTitle = title ?? book.title, askAuthor = author ?? book.author
        let (left, right) = askAuthor.isEmpty ? splitName(askTitle) : (askTitle, "")
        let ownISBN = book.isbn
        let agrees: (MetadataCandidate) -> Bool = {
            (ownISBN != nil && $0.isbn == ownISBN) || (BMShelf.titlesAgree(askTitle, $0.title) && BMShelf.authorsAgree(askAuthor, $0.authors))
                || (!right.isEmpty
                    && ((BMShelf.titlesAgree(left, $0.title) && BMShelf.authorsAgree(right, $0.authors))
                        || (BMShelf.titlesAgree(right, $0.title) && BMShelf.authorsAgree(left, $0.authors))))
        }
        // the first source to name the book is enough: the others need not be waited for
        let results = await search(title: askTitle, author: askAuthor, isbn: book.isbn, stopWhen: { $0.contains(where: agrees) })
        guard let match = results.first(where: agrees) else { return false }

        // the search took a while: change only these fields on the book as it is
        // now, so a position saved meanwhile is not rolled back
        var changed = false
        library.mutate(id) { current in
            let before = current
            // a Drive book is called by its file or folder name until something better is known
            if let guess = current.drive?.guessedTitle, current.title == guess, !match.title.isEmpty { current.title = match.title }
            if current.author.isEmpty, !match.authors.isEmpty { current.author = match.authors }
            if current.year == nil, !match.year.isEmpty { current.year = match.year }
            if current.bookDescription == nil, !match.summary.isEmpty { current.bookDescription = match.summary }
            if current.isbn == nil { current.isbn = match.isbn }
            if current.openLibraryId == nil { current.openLibraryId = match.openLibraryId }
            changed = current != before
        }
        if let pin = match.bookmasterId, book.bookmasterId == nil {
            library.updateBookMaster(id) { $0.bookmasterId = pin }
            changed = true
        }
        if !FileManager.default.fileExists(atPath: library.coverURL(for: book).path), !match.coverURLs.isEmpty {
            await applyCover(from: match.coverURLs, to: book, library: library)
            changed = true
        }
        return changed
    }
}

extension MetadataLookup {
    /// Books added from Google Drive have only a name to go by (their files are not down to read): look each up online
    /// for author, blurb, year and cover. A name like "Dune - Frank Herbert (1965)" is tried whole, then as title and
    /// author. One book at a time, so the sources are not hammered by a folder of hundreds.
    @MainActor
    static func enrichDriveBooks(_ ids: [UUID], library: LibraryStore) async {
        // a first sync of a big folder adds hundreds: the first forty are looked up now (the sources limit how often
        // they may be asked), the rest when their page is opened
        let ids = Array(ids.prefix(40))
        // three at a time: a folder of hundreds is not done one slow answer after another
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            func start() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { @MainActor in
                    guard let book = library.books.first(where: { $0.id == id }) else { return }
                    if await autoApply(to: id, library: library) { return }
                    let (title, author) = splitName(book.title)
                    if title != book.title || !author.isEmpty { _ = await autoApply(to: id, library: library, title: title, author: author) }
                }
            }
            for _ in 0 ..< 3 { start() }
            while await group.next() != nil { start() }
        }
    }

    /// "Dune - Frank Herbert (1965)" → ("Dune", "Frank Herbert"); "Dune by Frank Herbert" the same; brackets and
    /// underscores dropped.
    static func splitName(_ name: String) -> (title: String, author: String) {
        var text = name.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for separator in [" - ", " – ", " — ", " by "] {
            if let range = text.range(of: separator) {
                let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty { return (left, right) }
            }
        }
        return (text, "")
    }
}
