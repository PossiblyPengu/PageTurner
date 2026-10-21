import Foundation

/// Hardcover's catalogue (hardcover.app, GraphQL): good modern coverage, series, and community-chosen jackets.
/// This is the pure part — the request body and the reading of the answer — so the Linux checks can run it.
/// The network and the reader's token are in `HardcoverClient`.
struct HardcoverHit: Hashable {
    var title: String
    var authors: String
    var year: String
    var summary: String
    var isbn: String?
    var coverURL: URL?
    var series: String
}

enum HardcoverCore {
    static let endpoint = "https://api.hardcover.app/v1/graphql"

    /// A token as Hardcover shows it ("Bearer eyJ…") or bare: the header always carries "Bearer <token>".
    static func authorization(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer"), t.dropFirst(6).first?.isWhitespace ?? true {
            t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? nil : "Bearer \(t)"
    }

    /// The JSON body of one book search. The query text goes in as a variable, never spliced into the query.
    static func body(query: String, perPage: Int = 10) -> Data? {
        let q = "query($q: String!, $n: Int!) { search(query: $q, query_type: \"Book\", per_page: $n, page: 1) { results } }"
        let payload: [String: Any] = ["query": q, "variables": ["q": query, "n": perPage]]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// `data.search.results.hits[].document` — Typesense's shape, passed through by Hardcover. Anything missing is
    /// skipped, never fatal: an errors-only answer (a bad token) is an empty list.
    static func parse(_ data: Data) -> [HardcoverHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let search = (root["data"] as? [String: Any])?["search"] as? [String: Any]
        else { return [] }
        // `results` is a JSON scalar: an object, or (on some deployments) that object as a string
        var results = search["results"] as? [String: Any]
        if results == nil, let s = search["results"] as? String,
           let d = s.data(using: .utf8) {
            results = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        guard let hits = results?["hits"] as? [[String: Any]] else { return [] }
        return hits.compactMap { hit in
            guard let doc = hit["document"] as? [String: Any],
                  let title = (doc["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty
            else { return nil }
            let authors = (doc["author_names"] as? [String] ?? []).filter { !$0.isEmpty }.joined(separator: ", ")
            let year = (doc["release_year"] as? Int).map(String.init)
                ?? String(((doc["release_date"] as? String) ?? "").prefix(4))
            let isbns = doc["isbns"] as? [String] ?? []
            let cover = ((doc["image"] as? [String: Any])?["url"] as? String).flatMap { URL(string: $0) }
            let series = (doc["series_names"] as? [String])?.first ?? ""
            return HardcoverHit(
                title: title, authors: authors, year: year,
                summary: (doc["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                isbn: isbns.first(where: { $0.count == 13 }) ?? isbns.first,
                coverURL: cover, series: series)
        }
    }
}
