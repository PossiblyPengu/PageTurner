import Foundation

/// Where remote jackets are guessed from — the one place that knows Open
/// Library's URL shapes, so a screen never hand-builds `covers.openlibrary.org`
/// links. Pure Foundation so the Linux checks can run it.
enum CoverLinks {
    /// `?default=false` turns Open Library's blank stand-in into a 404, so a
    /// missing cover falls through to the next guess instead of rendering as
    /// an empty box. Sizes run big first.
    private static func ol(_ spec: String) -> [URL] {
        ["-L", "-M"].compactMap { URL(string: "https://covers.openlibrary.org/b/\(spec)\($0).jpg?default=false") }
    }

    static func coverID(_ id: Int) -> [URL] {
        id > 0 ? ol("id/\(id)") : []
    }

    static func isbn(_ raw: String?) -> [URL] {
        let digits = (raw ?? "").filter { $0.isNumber || $0 == "X" || $0 == "x" }
        return digits.count >= 10 ? ol("isbn/\(digits)") : []
    }

    static func openLibraryWork(_ olid: String?) -> [URL] {
        guard let olid, !olid.isEmpty else { return [] }
        return ol("olid/\(olid)")
    }

    /// Amazon's product-image lookup by ISBN-10 — a last resort: old books'
    /// ISBNs often answer with the current art after every catalogue has missed.
    /// Only a 978-prefixed thirteen-digit ISBN has a ten-digit form.
    static func amazon(_ raw: String?) -> [URL] {
        guard let isbn10 = isbn10(from: raw) else { return [] }
        return URL(string: "https://images-na.ssl-images-amazon.com/images/P/\(isbn10).01.LZZZZZZZ.jpg")
            .map { [$0] } ?? []
    }

    /// Archive.org's scan service: an Open Library edition's `ocaid` is the very
    /// scan the cover was photographed from — often the only jacket an old or
    /// public-domain book has anywhere.
    static func archiveScan(_ ocaid: String) -> [URL] {
        ocaid.isEmpty ? [] : (URL(string: "https://archive.org/services/img/\(ocaid)").map { [$0] } ?? [])
    }

    /// The Audible jacket — a bare `images/I/<id>.jpg` answers at whatever size
    /// the SL marker asks, biggest first.
    static func audibleArt(_ raw: String?) -> [URL] {
        guard let raw, !raw.isEmpty else { return [] }
        let stem = raw.hasSuffix(".jpg") ? String(raw.dropLast(4)) : raw
        return ["1500", "500"].compactMap { URL(string: "\(stem)._SL\($0)_.jpg") }
            + (URL(string: raw).map { [$0] } ?? [])
    }

    /// The 9+check-digit form Amazon's lookup still uses.
    private static func isbn10(from raw: String?) -> String? {
        var d = (raw ?? "").filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if d.count == 10 { return d.uppercased() }
        guard d.count == 13, d.hasPrefix("978") else { return nil }
        d = String(d.dropFirst(3).dropLast(1))
        let sum = d.enumerated().reduce(0) { $0 + (10 - $1.offset) * (Int(String($1.element)) ?? 0) }
        let check = (11 - sum % 11) % 11
        return d + (check == 10 ? "X" : String(check))
    }
}
