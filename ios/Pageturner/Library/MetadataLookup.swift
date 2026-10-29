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
    /// Other catalogues that named the same book — the same title and author
    /// under a second source merges into one card (`dedupe`), and this says who
    /// was folded in, so the sources bar can still name them.
    var contributors: [String] = []
    /// The BookMaster shelf row this is — applying it pins the book there, so a
    /// later push can never write a duplicate. Found by matching the candidate
    /// against the shelf copy the app keeps, not by asking BookMaster.
    var bookmasterId: String?
    /// The series the source names, and the book's place in it.
    var series: String?
    var seriesIndex: Double?
    /// A print page count, when the source has one — a median (Open Library)
    /// or the listed edition's (Google Books).
    var pages: Int?

    /// `id` is only for the list on screen; what is kept on disk is the rest.
    /// `coverURL` is read for lists cached by older builds, which kept one.
    enum CodingKeys: String, CodingKey {
        case title, authors, year, summary, isbn, openLibraryId, coverURL, coverURLs, source, contributors, bookmasterId,
             series, seriesIndex, pages
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
        contributors = try c.decodeIfPresent([String].self, forKey: .contributors) ?? []
        bookmasterId = try c.decodeIfPresent(String.self, forKey: .bookmasterId)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesIndex = try c.decodeIfPresent(Double.self, forKey: .seriesIndex)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
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
        try c.encodeIfPresent(contributors.isEmpty ? nil : contributors, forKey: .contributors)
        try c.encodeIfPresent(bookmasterId, forKey: .bookmasterId)
        try c.encodeIfPresent(series, forKey: .series)
        try c.encodeIfPresent(seriesIndex, forKey: .seriesIndex)
        try c.encodeIfPresent(pages, forKey: .pages)
    }
}

extension MetadataLookup {
    /// The same book from several sources collapses to one row — the first
    /// source's, with whatever it lacked (a blurb, an ISBN, a cover) filled in
    /// and the folded-in sources remembered as `contributors`, so the sources
    /// bar still names everyone who answered.
    static func dedupe(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var index: [String: Int] = [:]
        var byISBN: [String: Int] = [:]
        var out: [MetadataCandidate] = []
        for c in candidates {
            guard let key = dedupeKey(c) else { continue }
            let isbn = c.isbn.map { $0.filter { $0.isNumber || $0 == "X" || $0 == "x" } }.flatMap { $0.isEmpty ? nil : $0 }
            if let i = index[key] ?? isbn.flatMap({ byISBN[$0] }) {
                if let isbn, byISBN[isbn] == nil { byISBN[isbn] = i }
                if out[i].summary.isEmpty { out[i].summary = c.summary }
                if out[i].isbn == nil { out[i].isbn = c.isbn }
                if out[i].openLibraryId == nil { out[i].openLibraryId = c.openLibraryId }
                // merge cover guesses, keeping the survivor's own first
                out[i].coverURLs.append(contentsOf: c.coverURLs.filter { !out[i].coverURLs.contains($0) })
                if out[i].year.isEmpty { out[i].year = c.year }
                if out[i].series == nil { out[i].series = c.series; out[i].seriesIndex = c.seriesIndex }
                if out[i].pages == nil { out[i].pages = c.pages }
                // the folded-in match's shelf pin is a fact, not a guess — keep it
                if out[i].bookmasterId == nil { out[i].bookmasterId = c.bookmasterId }
                // the folded-in match keeps a name in the sources line
                for name in [c.source] + c.contributors
                where name != out[i].source && !out[i].contributors.contains(name) {
                    out[i].contributors.append(name)
                }
                continue
            }
            index[key] = out.count
            if let isbn { byISBN[isbn] = out.count }
            out.append(c)
        }
        return out
    }

    /// One book, however each catalogue wrote it: the title folded (case, accents, a series note in brackets gone)
    /// and the lead author's first initial and surname — "Herbert, Frank", "Frank Herbert", "F. Herbert" and
    /// "Frank Herbert, Brian Herbert" all lead with F. Herbert (and Brian Herbert's books stay apart). Nil for a
    /// match with no title worth the name.
    static func dedupeKey(_ c: MetadataCandidate) -> String? {
        let title = BookMatch.fold(c.title)
        guard !title.isEmpty else { return nil }
        var lead = c.authors
        if let r = lead.range(of: #";|&| and "#, options: [.regularExpression, .caseInsensitive]) {
            lead = String(lead[..<r.lowerBound])
        }
        // "Surname, Given" names the surname first; "Given Surname, Other Person" lists two people
        let parts = lead.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var names: [String]
        if parts.count >= 2, !parts[0].contains(" ") {
            names = BookMatch.fold(parts[1] + " " + parts[0]).split(separator: " ").map(String.init)
        } else {
            names = BookMatch.fold(parts.first ?? "").split(separator: " ").map(String.init)
        }
        let surname = names.popLast() ?? ""
        let initial = names.first.map { String($0.prefix(1)) } ?? ""
        return title + "|" + initial + surname
    }
}

/// Book metadata lookup: the same catalogues BookMaster asks — Open Library,
/// Google Books and Apple Books through `CatalogueSearch` — never BookMaster
/// itself. A match that lands on the reader's shelf is pinned from the shelf
/// copy the app already keeps, so applying it can never push a duplicate.
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

    /// "1.5" parses; so do "nan" and "inf" — and JSONSerialization answers a
    /// runaway exponent like `1e999` as +inf too. Those would fail the encode
    /// of any catalogue or cache they end up stored in, so only finite counts.
    private static func finite(_ d: Double?) -> Double? {
        d?.isFinite == true ? d : nil
    }

    private static func finite(_ s: String?) -> Double? {
        finite(s.flatMap(Double.init))
    }

    /// All sources at once. `progress` hears the merged list each time one answers (the fastest shows at once, the
    /// slowest only adds); `stopWhen` ends the search early once the list so far holds what the caller wanted.
    /// `interactive` is the fast lane for a search the reader is watching —
    /// bulk fills take the polite one. `audio` adds Audible's catalogue —
    /// a real source of hi-res audio jackets a print search needn't pay for.
    static func search(
        title: String, author: String, isbn: String? = nil, interactive: Bool = true,
        audio: Bool = false,
        progress: (@MainActor ([MetadataCandidate]) -> Void)? = nil,
        stopWhen: (([MetadataCandidate]) -> Bool)? = nil
    ) async -> [MetadataCandidate] {
        // a list made without Hardcover is not what a reader with a token should be handed back
        let key = (title + "|" + author + "|" + (isbn ?? "") + (HardcoverClient.hasToken ? "|hc" : "") + (audio ? "|aud" : "")).lowercased()
        if let hit = await MainActor.run(body: { recalled(key) }) {
            // pins are worked out fresh: the shelf may have changed since the list was kept
            let pinned = await MainActor.run { pinToShelf(hit) }
            await progress?(pinned)
            return pinned
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
        let extraSlots = extra == nil ? 0 : 2
        let audioSlots = audio ? asks.count + extraSlots / 2 : 0
        // Hardcover answers only with the reader's own token (Settings → Library & import)
        let hardcover = HardcoverClient.hasToken
        let hardcoverBase = asks.count * 2 + extraSlots + audioSlots
        let hardcoverSlots = hardcover ? asks.count + extraSlots / 2 : 0
        var slots: [[MetadataCandidate]] = Array(repeating: [], count: hardcoverBase + hardcoverSlots)
        var stopped = false
        var hardcoverFailed = false
        await withTaskGroup(of: (Int, [MetadataCandidate], Bool).self) { group in
            for (n, ask) in asks.enumerated() {
                group.addTask { (n * 2, await catalogue(ask.title, author: ask.author, interactive: interactive), false) }
                group.addTask { (n * 2 + 1, await googleBooks(title: ask.title, author: ask.author), false) }
            }
            if let extra {
                group.addTask { (asks.count * 2, await catalogue(extra, interactive: interactive), false) }
                group.addTask { (asks.count * 2 + 1, await googleBooks(query: "isbn:\(extra)"), false) }
            }
            for (n, ask) in asks.enumerated() where audio {
                group.addTask { (asks.count * 2 + extraSlots + n, await audible(title: ask.title, author: ask.author), false) }
            }
            if audio, let extra {
                group.addTask { (asks.count * 2 + extraSlots + asks.count, await audible(query: extra), false) }
            }
            if hardcover {
                for (n, ask) in asks.enumerated() {
                    group.addTask {
                        let (list, failed) = await hardcoverBooks([ask.title, ask.author].filter { !$0.isEmpty }.joined(separator: " "))
                        return (hardcoverBase + n, list, failed)
                    }
                }
                if let extra {
                    group.addTask {
                        let (list, failed) = await hardcoverBooks(extra)
                        return (hardcoverBase + asks.count, list, failed)
                    }
                }
            }
            for await (index, list, failed) in group {
                slots[index] = list
                hardcoverFailed = hardcoverFailed || failed
                let deduped = dedupe(slots.flatMap { $0 })
                let merged = await MainActor.run { pinToShelf(deduped) }
                await progress?(merged)
                if let stopWhen, stopWhen(merged) {
                    stopped = true
                    group.cancelAll()
                    break
                }
            }
        }
        var deduped = dedupe(slots.flatMap { $0 })
        // Wikimedia's copy of a cover rides on the ISBN — one extra ask, only
        // where a typed or scanned ISBN gave it something to find
        if let extra {
            let wiki = await wikimediaCovers(isbn: extra)
            if !wiki.isEmpty {
                deduped = deduped.map { c in
                    guard ISBN.normalize(c.isbn ?? "") == extra else { return c }
                    var c = c
                    c.coverURLs.append(contentsOf: wiki.filter { !c.coverURLs.contains($0) })
                    return c
                }
            }
        }
        // a search cut short, or one where nothing came back (the network, not the book), is not worth remembering
        // (kept without the shelf pins, which are worked out when the list is handed out)
        if !stopped, !Task.isCancelled, !deduped.isEmpty, !hardcoverFailed {
            await MainActor.run { remember(key, deduped) }
        }
        return await MainActor.run { pinToShelf(deduped) }
    }

    // MARK: - The catalogues

    /// Open Library and Apple Books through `CatalogueSearch`, as candidates.
    private static func catalogue(_ title: String, author: String = "", interactive: Bool) async -> [MetadataCandidate] {
        let query = [title, author].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return [] }
        let reply = await CatalogueSearch.search(query, limit: 12, interactive: interactive)
        return reply.books.map { hit in
            MetadataCandidate(
                title: hit.title,
                authors: hit.author == "Unknown" ? "" : hit.author,
                year: hit.publishedYear.map(String.init) ?? "",
                summary: hit.summary ?? "",
                isbn: hit.isbn.flatMap { ISBN.normalize($0) },
                openLibraryId: hit.openLibraryId.isEmpty ? nil : hit.openLibraryId,
                coverURLs: hit.coverURLs,
                source: hit.source,
                pages: hit.totalPages)
        }
    }

    /// A candidate that names a book already on the reader's shelf is pinned
    /// to that row — so applying it can never push a duplicate — worked out
    /// from the shelf copy the app keeps, not asked of BookMaster.
    @MainActor
    private static func pinToShelf(_ list: [MetadataCandidate]) -> [MetadataCandidate] {
        let rows = BookMaster.shared.shelfRows
        guard !rows.isEmpty else { return list }
        return list.map { c in
            guard c.bookmasterId == nil,
                  let row = BMShelf.match(title: c.title, author: c.authors,
                                          isbn: c.isbn, openLibraryId: c.openLibraryId, in: rows)
            else { return c }
            var c = c
            c.bookmasterId = row.userBookId
            // the shelf row's own jacket — including one this app pushed up —
            // is the strongest guess of all. The pin is a fact, not a source:
            // the card badges it rather than renaming where the match came from.
            c.coverURLs.insert(contentsOf: row.coverURLs.filter { !c.coverURLs.contains($0) }, at: 0)
            return c
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
            URLQueryItem(name: "fields", value: "items(id,volumeInfo(title,authors,publishedDate,imageLinks,description,industryIdentifiers,seriesInfo,pageCount))"),
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
            // the publisher's frontcover serves the art at real size, far above
            // the 128px imageLinks thumbnail
            if let vid = item["id"] as? String,
               let front = URL(string: "https://books.google.com/books/publisher/content?id=\(vid)&printsec=frontcover&img=1&zoom=3") {
                covers.append(front)
            }
            if let links = info["imageLinks"] as? [String: Any],
               let thumb = (links["thumbnail"] as? String) ?? (links["smallThumbnail"] as? String),
               // Google serves covers over http — force https for ATS; edge=curl
               // is a decorative fold-shadow baked into the thumbnail
               let url = URL(string: thumb
                                .replacingOccurrences(of: "&edge=curl", with: "")
                                .replacingOccurrences(of: "http://", with: "https://"))
            {
                covers.append(url)
            }
            let identifiers = (info["industryIdentifiers"] as? [[String: Any]] ?? [])
                .compactMap { $0["identifier"] as? String }
            let isbn = ISBN.best(of: identifiers)
            covers += CoverLinks.isbn(isbn)
            let seriesEntry = ((info["seriesInfo"] as? [String: Any])?["series"] as? [[String: Any]])?.first
            return MetadataCandidate(
                title: t, authors: authors, year: year,
                summary: BookText.plain(fromHTML: info["description"] as? String ?? ""),
                isbn: isbn, coverURLs: covers, source: "Google Books",
                series: seriesEntry?["title"] as? String,
                seriesIndex: finite(seriesEntry?["issueNumber"] as? String),
                pages: info["pageCount"] as? Int)
        }
    }

    // MARK: - Hardcover

    /// The hits, and whether asking went wrong — a failed Hardcover call must not be remembered as an empty one.
    private static func hardcoverBooks(_ query: String) async -> ([MetadataCandidate], Bool) {
        let (hits, failed) = await HardcoverClient.search(query)
        return (hits.map { hit in
            MetadataCandidate(
                title: hit.title, authors: hit.authors, year: hit.year, summary: hit.summary,
                isbn: hit.isbn.flatMap { ISBN.normalize($0) },
                coverURLs: (hit.coverURL.map { [$0] } ?? []) + CoverLinks.isbn(hit.isbn) + CoverLinks.amazon(hit.isbn),
                source: "Hardcover",
                series: hit.series.isEmpty ? nil : hit.series,
                seriesIndex: hit.seriesIndex)
        }, failed)
    }

    // MARK: - Audible

    /// Audible's catalogue through the community Audnexus mirror — a free-text
    /// search returning the audiobook's own square art, its audio ISBN and its
    /// blurb. Only asked when the caller says the book is audio: for a print
    /// book its hits would only ever be the same work on CD.
    private static func audible(title: String, author: String) async -> [MetadataCandidate] {
        await audible(query: [title, author].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func audible(query q: String) async -> [MetadataCandidate] {
        guard !q.isEmpty,
              var comp = URLComponents(string: "https://api.audnex.us/books/search") else { return [] }
        comp.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comp.url,
              let (data, _) = try? await session.data(from: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return items.prefix(8).compactMap { item in
            guard let t = item["title"] as? String, !t.isEmpty else { return nil }
            let authors = ((item["authors"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: ", ")
            let isbn = ISBN.best(of: [(item["isbn"] as? String) ?? ""])
            var covers = CoverLinks.audibleArt(item["image"] as? String)
            covers += CoverLinks.isbn(isbn)
            // "seriesPrimary"/"seriesSecondary": {name, position} — the run the book is in
            let run = (item["seriesPrimary"] as? [String: Any]) ?? (item["seriesSecondary"] as? [String: Any])
            return MetadataCandidate(
                title: t, authors: authors,
                year: String((item["releaseDate"] as? String ?? "").prefix(4)),
                summary: BookText.plain(fromHTML: (item["description"] as? String) ?? (item["summary"] as? String) ?? ""),
                isbn: isbn, coverURLs: covers, source: "Audible",
                series: run?["name"] as? String,
                seriesIndex: finite(run?["position"] as? Double) ?? finite(run?["position"] as? String))
        }
    }

    // MARK: - Wikimedia

    /// Cover scans Wikimedia Commons holds for an ISBN, through Inventaire's
    /// image endpoint — `/img/entities/<hash>` under `inventaire.io`. One ask
    /// per search, only when an ISBN was given.
    private static func wikimediaCovers(isbn: String) async -> [URL] {
        guard var comp = URLComponents(string: "https://inventaire.io/api/entities/images") else { return [] }
        comp.queryItems = [URLQueryItem(name: "uris", value: "isbn:\(isbn)")]
        guard let url = comp.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String: Any]
        else { return [] }
        return images.values.flatMap { entry in
            ((entry as? [String: Any])?["claims"] as? [String] ?? [])
                .compactMap { URL(string: "https://inventaire.io" + $0) }
        }
    }

    // MARK: - Applying

    /// Download a candidate's cover into the covers folder for `book`. `urls`
    /// is the fallback chain: the first that answers with a real image wins.
    /// True only when an image was fetched and written — callers say so.
    @discardableResult
    static func applyCover(from urls: [URL], to book: Book, library: LibraryStore) async -> Bool {
        guard let image = await CoverFetch.firstImage(in: urls),
              let jpeg = image.jpegData(compressionQuality: 0.85)
        else { return false }
        return await MainActor.run {
            do {
                try jpeg.write(to: library.coverURL(for: book))
                library.coverChanged()
                return true
            } catch {
                Log.error("metadata", "cover write failed: \(error.localizedDescription)")
                return false
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
        let ownISBN = book.isbn.flatMap(ISBN.normalize)
        // the details are filled in without being looked at, so a match has to be the book: its ISBN, or the title
        // with an author that agrees. A name with an author in it ("Dune - Frank Herbert") is held to that author,
        // either way round; a book with no author at all takes only a match that names one.
        let agrees: (MetadataCandidate) -> Bool = { c in
            if ownISBN != nil, c.isbn == ownISBN { return true }
            if !right.isEmpty {
                return (BMShelf.titlesAgree(left, c.title) && !c.authors.isEmpty && BMShelf.authorsAgree(right, c.authors))
                    || (BMShelf.titlesAgree(right, c.title) && !c.authors.isEmpty && BMShelf.authorsAgree(left, c.authors))
            }
            return BMShelf.titlesAgree(askTitle, c.title) && !c.authors.isEmpty && BMShelf.authorsAgree(askAuthor, c.authors)
        }
        // the first source to name the book is enough: the others need not be waited for
        let results = await search(title: askTitle, author: askAuthor, isbn: book.isbn,
                                   interactive: false, audio: book.isAudio,
                                   stopWhen: { $0.contains(where: agrees) })
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
            if current.series == nil { current.series = match.series; current.seriesIndex = match.seriesIndex }
            if current.pages == nil { current.pages = match.pages }
            changed = current != before
        }
        if let pin = match.bookmasterId, book.bookmasterId == nil {
            library.updateBookMaster(id) { $0.bookmasterId = pin }
            changed = true
        }
        if !FileManager.default.fileExists(atPath: library.coverURL(for: book).path), !match.coverURLs.isEmpty,
           await applyCover(from: match.coverURLs, to: book, library: library) {
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
