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
}
