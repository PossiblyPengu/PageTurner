import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One catalogue result — what BookMaster's `SearchResult` carries, plus the
/// shelf state this device already knows: a hit that is already shelved comes
/// back with its pin, so applying it can never push a duplicate.
struct CatalogueHit: Hashable {
    /// Stable identity among lookalikes: "ol:<work id>" or "apple:<track id>".
    var key: String
    /// "Open Library" or "Apple Books".
    var source: String
    var openLibraryId: String
    var title: String
    var author: String
    var coverUrl: String?
    /// A blurb, when the source carries one — Apple's does, Open Library's
    /// search does not.
    var summary: String?
    var genres: [String]
    var publishedYear: Int?
    var isbn: String?
    var totalPages: Int?
    /// The shelf row this book already is, when the kept shelf says so —
    /// filled by `CatalogueSearch.pin`.
    var userBookId: String? = nil
    var bookId: String? = nil
    var status: String? = nil

    /// Jacket guesses, best first: the hit's own art, then Open Library's by
    /// ISBN and work id — each 404ing cleanly into the next.
    var coverURLs: [URL] {
        var seen = Set<URL>()
        return ((coverUrl.flatMap { URL(string: $0) }.map { [$0] } ?? [])
            + CoverLinks.isbn(isbn) + CoverLinks.openLibraryWork(openLibraryId))
            .filter { seen.insert($0).inserted }
    }
}

extension CatalogueHit: BookRank.Rankable {}

/// What a catalogue search answers.
struct CatalogueReply {
    var books: [CatalogueHit]
    /// The query as it was probably meant, when a slip was corrected.
    var correctedTo: String?
    /// True when no catalogue could be reached at all — "couldn't search",
    /// not "no matches".
    var failed: Bool
}

/// Finding a book, the way BookMaster's own page does it.
///
/// The same two catalogues, asked directly from the device — Open Library's
/// free-text search and Apple's ebook catalogue — never through BookMaster,
/// whose `/pageturner/search` only proxied this for it. Open Library leads;
/// Apple answers in parallel, spells the query as it was probably meant,
/// lends its publisher-sharp covers to results that need them, and stands in
/// for the whole list when Open Library cannot be reached. This is
/// `src/lib/search.ts` ported, so a book lands in the same place whichever
/// app found it.
enum CatalogueSearch {
    /// The catalogue calls may take ten seconds on a slow day; past that they
    /// are not coming.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// One lane per source and pace: the bulk lane keeps a whole shelf inside
    /// the per-address allowance, while a search typed at the box cannot wait
    /// behind it — the interactive gaps sit inside what a short burst is
    /// allowed (200ms for Open Library, 400ms for Apple).
    private actor Lane {
        private var lastCall: Date = .distantPast
        func pace(_ gap: TimeInterval) async {
            let now = Date()
            let readyAt = max(now, lastCall.addingTimeInterval(gap))
            lastCall = readyAt
            if readyAt > now {
                try? await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000))
            }
        }
    }

    private static let olBulk = Lane()
    private static let olInteractive = Lane()
    private static let appleBulk = Lane()
    private static let appleInteractive = Lane()

    /// Answers already given this session, so a repeat costs nothing.
    private actor SearchCache {
        private var table: [String: Data] = [:]
        func get(_ key: String) -> Data? { table[key] }
        func set(_ key: String, _ data: Data) { table[key] = data }
    }
    private static let searchCache = SearchCache()

    // MARK: - The search

    /// Search the catalogues. `interactive` picks the fast lane for a query
    /// typed at a search box; background sweeps take the polite one.
    static func search(_ query: String, limit: Int = 24, interactive: Bool = true) async -> CatalogueReply {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return CatalogueReply(books: [], correctedTo: nil, failed: false) }

        async let olTask = openLibrary(query: trimmed, limit: limit, interactive: interactive)
        async let appleTask = apple(query: trimmed, interactive: interactive)
        let olHits = await olTask
        let appleHits = await appleTask

        var books = olHits ?? []

        // Open Library matches words exactly, so a slip — "forth wing",
        // "kristen hannah" — finds pamphlets and strangers. Apple forgives it,
        // and its hits spell what was meant: ask Open Library again in those
        // words, and rank everything by whichever spelling it answers.
        let meant = appleHits.flatMap {
            BookRank.correctQuery(trimmed, found: $0.map { ($0.title, $0.author) })
        }
        var correctedTo: String?
        if let meant, olHits != nil,
           let fixed = await openLibrary(query: meant, limit: limit, interactive: interactive),
           !fixed.isEmpty {
            books = BookRank.rankResults(fixed + books, query: trimmed, meant: meant)
            correctedTo = meant
        }
        let score: (CatalogueHit) -> Double = { hit in
            max(BookRank.relevance(title: hit.title, author: hit.author, query: trimmed),
                meant.map { BookRank.relevance(title: hit.title, author: hit.author, query: $0) } ?? 0)
        }

        if books.isEmpty, let appleHits {
            // Ranked like any other list: Apple lists the ebook and the
            // audiobook as two hits, and puts summaries of a bestseller right
            // beside it.
            books = BookRank.rankResults(appleHits, query: trimmed, meant: meant)
        } else if let appleHits {
            // The same book under another catalogue's id is a duplicate, not a
            // second result — but its cover is worth taking. Apple's is the
            // publisher's current art, sharp at any size; Open Library's is
            // whichever edition was catalogued first.
            for i in books.indices {
                guard let hit = appleHits.first(where: {
                    BookMatch.titlesMatch(books[i].title, $0.title)
                        && BookMatch.authorsMatch(books[i].author, [$0.author])
                        && BookMatch.volumesAgree(books[i].title, $0.title)
                }), let cover = hit.coverUrl, cover != books[i].coverUrl else { continue }
                books[i].coverUrl = cover
            }
            // A strong Apple match that Open Library does not have at all —
            // usually a release newer than its catalogue — joins the list
            // rather than being dropped for arriving second.
            let missing = appleHits.filter { h in
                score(h) >= 1.5
                    && !books.contains {
                        BookMatch.titlesMatch($0.title, h.title)
                            && BookMatch.authorsMatch($0.author, [h.author])
                    }
            }
            if !missing.isEmpty {
                books = BookRank.rankResults(books + missing, query: trimmed, meant: meant)
            }
        }

        return CatalogueReply(
            books: books,
            correctedTo: correctedTo,
            // BookMaster's page throws here: nothing to show and the one
            // catalogue that could still answer had nothing either.
            failed: olHits == nil && (appleHits?.isEmpty ?? true))
    }

    /// Flag the hits that are already shelved — the pin a later write
    /// resolves by, from the shelf copy the app keeps rather than another
    /// question for BookMaster.
    static func pin(_ books: inout [CatalogueHit], to rows: [BMShelfRow]) {
        for i in books.indices where books[i].userBookId == nil {
            guard let row = BMShelf.match(
                title: books[i].title, author: books[i].author,
                isbn: books[i].isbn, openLibraryId: books[i].openLibraryId,
                in: rows)
            else { continue }
            books[i].userBookId = row.userBookId
            books[i].bookId = row.bookId
            books[i].status = row.status
        }
    }

    // MARK: - Open Library

    /// The fuller field list — the same set BookMaster's search asks for, so
    /// results look identical whichever app made the call.
    private static let searchFields =
        "key,title,author_name,cover_i,first_publish_year,number_of_pages_median,subject,isbn," +
        "editions,editions.title,editions.cover_i,editions.language"

    /// The free-text search. Nil on failure rather than empty: a refused
    /// search and a genuine miss are different answers, and only the second
    /// should read as "nothing found".
    private static func openLibrary(query: String, limit: Int, interactive: Bool) async -> [CatalogueHit]? {
        guard var comp = URLComponents(string: "https://openlibrary.org/search.json") else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: searchFields),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comp.url else { return nil }

        if let cached = await searchCache.get(url.absoluteString) {
            return parseOpenLibrary(cached, query: query)
        }
        await (interactive ? olInteractive : olBulk).pace(interactive ? 0.2 : 0.7)
        guard let (data, res) = try? await session.data(from: url),
              (res as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        await searchCache.set(url.absoluteString, data)
        return parseOpenLibrary(data, query: query)
    }

    private static func parseOpenLibrary(_ data: Data, query: String) -> [CatalogueHit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]]
        else { return [] }
        return BookRank.rankResults(
            docs.map { normaliseOpenLibrary($0, query: query) }.filter { !$0.openLibraryId.isEmpty },
            query: query)
    }

    private static func normaliseOpenLibrary(_ doc: [String: Any], query: String) -> CatalogueHit {
        let author = (doc["author_name"] as? [String])?.first ?? "Unknown"
        // The edition that best matches the query, so a work filed under a
        // translation's title can still show the one that was searched for.
        let edition = (((doc["editions"] as? [String: Any])?["docs"]) as? [[String: Any]])?.first
        let shown = BookRank.preferEdition(
            work: (title: doc["title"] as? String ?? "Unknown",
                   coverI: doc["cover_i"] as? Int),
            edition: edition.map {
                BookRank.EditionHint(
                    title: $0["title"] as? String,
                    coverI: $0["cover_i"] as? Int,
                    languages: $0["language"] as? [String])
            },
            author: author,
            query: query)

        let olid = (doc["key"] as? String)?.replacingOccurrences(of: "/works/", with: "") ?? ""
        let isbn = (doc["isbn"] as? [String])?.first
        // A cover id is a cover Open Library certainly holds; an ISBN is a
        // guess — worth it when results are a wall of covers.
        var cover: String?
        if let coverI = shown.coverI {
            cover = "https://covers.openlibrary.org/b/id/\(coverI)-L.jpg"
        } else if let isbn {
            cover = coverFromIsbn(isbn)
        }

        return CatalogueHit(
            key: "ol:\(olid)",
            source: "Open Library",
            openLibraryId: olid,
            title: shown.title,
            author: author,
            coverUrl: cover,
            summary: nil,
            genres: ((doc["subject"] as? [String]) ?? []).prefix(5).map { $0 },
            publishedYear: doc["first_publish_year"] as? Int,
            isbn: isbn,
            totalPages: doc["number_of_pages_median"] as? Int)
    }

    /// The cover for an ISBN, if Open Library holds one. `default=false` turns
    /// the 1x1 placeholder it answers for a missing cover into a 404.
    private static func coverFromIsbn(_ isbn: String) -> String? {
        let digits = isbn.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
        guard BookMatch.matches(#"^(\d{9}[\dXx]|\d{13})$"#, in: digits) else { return nil }
        return "https://covers.openlibrary.org/b/isbn/\(digits)-L.jpg?default=false"
    }

    // MARK: - Apple Books

    /// Apple's artwork at a usable size: the API always reports a 100px
    /// thumbnail, but the same asset is served at any dimension by rewriting
    /// that segment.
    private static func artwork(_ url: String?) -> String? {
        url?.replacingOccurrences(of: #"/\d+x\d+bb\."#, with: "/600x600bb.", options: .regularExpression)
    }

    /// Search Apple's ebook catalogue — the second shelf to check when Open
    /// Library comes back empty, and a source of covers where it did not.
    /// Nil when Apple could not be asked, so the caller can tell a dead
    /// catalogue from a real miss.
    private static func apple(query: String, limit: Int = 15, interactive: Bool) async -> [CatalogueHit]? {
        guard var comp = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comp.url else { return nil }
        if let cached = await searchCache.get(url.absoluteString) {
            return parseApple(cached)
        }

        // A 403 or 429 is "could not ask", not an answer — one backed-off
        // retry keeps a single throttled moment from writing the search off.
        let lane = interactive ? appleInteractive : appleBulk
        let gap: TimeInterval = interactive ? 0.4 : 3
        for attempt in 0 ... 1 {
            await lane.pace(attempt == 0 ? gap : gap * 4)
            guard let (data, res) = try? await session.data(from: url) else {
                if attempt == 0 { continue } else { return nil }
            }
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 || status == 429 {
                if attempt == 0 { continue }
                return nil
            }
            guard status == 200 else { return nil }
            await searchCache.set(url.absoluteString, data)
            return parseApple(data)
        }
        return nil
    }

    private static func parseApple(_ data: Data) -> [CatalogueHit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap { r in
            guard let title = r["trackName"] as? String, !title.isEmpty,
                  let author = r["artistName"] as? String, !author.isEmpty
            else { return nil }
            let year = (r["releaseDate"] as? String)?.prefix(4)
            return CatalogueHit(
                key: "apple:\((r["trackId"] as? Int).map { String($0) } ?? "\(title)|\(author)")",
                source: "Apple Books",
                openLibraryId: "",
                title: title,
                author: author,
                coverUrl: artwork(r["artworkUrl100"] as? String),
                summary: (r["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                // Every ebook is filed under "Books", which says nothing.
                genres: ((r["genres"] as? [String]) ?? []).filter { $0.lowercased() != "books" }.prefix(5).map { $0 },
                publishedYear: year.flatMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil },
                isbn: nil,
                totalPages: nil)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
