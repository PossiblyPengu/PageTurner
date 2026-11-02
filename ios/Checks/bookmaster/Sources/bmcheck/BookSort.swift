import Foundation

/// The library grid's search and sort — pulled off `LibraryStore` (which needs
/// UIKit) so the same rules the grid shows run in the Linux checks. The store's
/// `sortedBooks(order:query:)` is these two, one after the other.
enum BookSort {
    /// The orders the sort menu offers.
    enum Order: String, CaseIterable, Identifiable {
        case recent, added, title, author, series, progress, rating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Recently Opened"
            case .added: return "Recently Added"
            case .title: return "Title"
            case .author: return "Author"
            case .series: return "Series"
            case .progress: return "Progress"
            case .rating: return "Rating"
            }
        }
    }

    /// Every word of the query must match the title, the author or the series,
    /// ignoring case and accents — so "herbert dune" and "stormlight" both hit.
    static func filtered(_ books: [Book], query: String) -> [Book] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return books }
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return books.filter { b in
            tokens.allSatisfy { b.title.localizedStandardContains($0)
                || b.author.localizedStandardContains($0)
                || (b.series?.localizedStandardContains($0) ?? false) }
        }
    }

    /// The visible order — ties always fall back to the title so a shelf never
    /// shuffles between launches.
    static func sorted(_ books: [Book], order: Order) -> [Book] {
        let list = books
        switch order {
        case .recent:
            return list.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .added:
            return list.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return list.sorted {
                $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending
            }
        case .author:
            // books with no author last, then by last name, then by title
            return list.sorted { a, b in
                if a.author.isEmpty != b.author.isEmpty { return !a.author.isEmpty }
                let c = a.sortAuthor.localizedStandardCompare(b.sortAuthor)
                return c == .orderedSame
                    ? a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending
                    : c == .orderedAscending
            }
        case .series:
            // a series together, in reading order; books outside any series after them, by title
            return list.sorted { a, b in
                let sa = a.series ?? "", sb = b.series ?? ""
                if sa.isEmpty != sb.isEmpty { return !sa.isEmpty }
                if sa != sb { return sa.localizedStandardCompare(sb) == .orderedAscending }
                if let x = a.seriesIndex, let y = b.seriesIndex, x != y { return x < y }
                return a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending
            }
        case .progress:
            // furthest along first; books not started last
            return list.sorted { a, b in
                let pa = a.progression ?? -1, pb = b.progression ?? -1
                return pa != pb ? pa > pb
                    : a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending
            }
        case .rating:
            // best rated first; unrated last
            return list.sorted { a, b in
                let ra = a.bmRating ?? 0, rb = b.bmRating ?? 0
                return ra != rb ? ra > rb
                    : a.sortTitle.localizedStandardCompare(b.sortTitle) == .orderedAscending
            }
        }
    }
}
