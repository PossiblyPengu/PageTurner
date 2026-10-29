import Foundation
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

