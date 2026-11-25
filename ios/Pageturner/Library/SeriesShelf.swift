import Foundation

/// The books of each series together, in reading order, with how far through it the reader is and which book comes
/// next. Pure, so it is checked on Linux.
///
/// A volume can be here twice — the ebook and the audiobook — so the counting is by volume: the same number, or
/// without numbers the same title. A volume is read when either is finished.
enum SeriesShelf {
    struct Series: Identifiable, Equatable {
        var id: String { key }
        /// The series name folded (`key(_:)`): two spellings of one series are one.
        let key: String
        /// The name as the books give it.
        let name: String
        /// In reading order: by number, then those without one by title.
        let books: [Book]
        /// How many volumes, and how many of them are read.
        let volumes: Int
        let finished: Int
        /// What to read next: the volume after the furthest one read (the one under way, with nothing read yet);
        /// nil when every volume is read.
        let next: Book?
    }

    /// A book counts as read from here on.
    static let finishedAt = 0.995

    /// Every series in `books` — the one read most lately first.
    static func groups(_ books: [Book]) -> [Series] {
        var byKey: [String: [Book]] = [:]
        for book in books {
            guard let name = book.series, !key(name).isEmpty else { continue }
            byKey[key(name), default: []].append(book)
        }
        let series = byKey.map { key, members -> Series in
            let ordered = inOrder(members)
            let volumes = volumeRuns(ordered)
            let read = volumes.filter { $0.contains(where: isFinished) }.count
            return Series(
                key: key,
                name: displayName(ordered),
                books: ordered,
                volumes: volumes.count,
                finished: read,
                next: next(in: volumes, after: nil))
        }
        func lastOpened(_ s: Series) -> Date { s.books.compactMap(\.lastOpenedAt).max() ?? .distantPast }
        return series.sorted {
            let a = lastOpened($0), b = lastOpened($1)
            if a != b { return a > b }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The book to read after `book` in its series: the first volume after it not yet read — the same kind (an
    /// ebook after an ebook) when both are in the library. Nil outside a series, or when the rest are read.
    static func next(after book: Book, in books: [Book]) -> Book? {
        guard let name = book.series else { return nil }
        let folded = key(name)
        guard !folded.isEmpty else { return nil }
        let volumes = volumeRuns(inOrder(books.filter { $0.series.map(key) == folded }))
        guard let here = volumes.firstIndex(where: { $0.contains { $0.id == book.id } }) else { return nil }
        return next(in: volumes, after: here, like: book)
    }

    /// Two spellings of a series are one when they differ in case, accents, spacing or a leading "The".
    static func key(_ name: String) -> String {
        var folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded
    }

    /// "Book 2 of Dune", "Dune" when it has no number.
    static func place(of book: Book) -> String? {
        guard let name = book.series?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        guard let index = book.seriesIndex, index.isFinite, index > 0 else { return name }
        let number = index == index.rounded() ? String(Int(index)) : String(format: "%g", index)
        return "Book \(number) of \(name)"
    }

    // MARK: -

    private static func isFinished(_ book: Book) -> Bool { (book.progression ?? 0) >= finishedAt }

    private static func inOrder(_ books: [Book]) -> [Book] {
        books.sorted { a, b in
            switch (a.seriesIndex, b.seriesIndex) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let byTitle = a.title.localizedCaseInsensitiveCompare(b.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return !a.isAudio && b.isAudio   // the ebook before its audiobook
            }
        }
    }

    /// The ordered books cut into volumes: neighbours with the same number, or without numbers the same title.
    private static func volumeRuns(_ ordered: [Book]) -> [[Book]] {
        var runs: [[Book]] = []
        for book in ordered {
            if let last = runs.last?.last, sameVolume(last, book) {
                runs[runs.count - 1].append(book)
            } else {
                runs.append([book])
            }
        }
        return runs
    }

    private static func sameVolume(_ a: Book, _ b: Book) -> Bool {
        if let x = a.seriesIndex, let y = b.seriesIndex { return x == y }
        guard a.seriesIndex == nil, b.seriesIndex == nil else { return false }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedSame
    }

    /// The volume to read after `here` (or, with no `here`, after the furthest one read), in the kind `like` is
    /// when it has one, else the edition under way, else the first.
    private static func next(in volumes: [[Book]], after here: Int?, like: Book? = nil) -> Book? {
        let from: Int
        if let here {
            from = here + 1
        } else if let lastRead = volumes.lastIndex(where: { $0.contains(where: isFinished) }) {
            from = lastRead + 1
        } else {
            // nothing read yet: the one under way, else the first
            let started = volumes.firstIndex { $0.contains { ($0.progression ?? 0) > 0.001 } }
            from = started ?? 0
        }
        guard let volume = volumes.dropFirst(from).first(where: { !$0.contains(where: isFinished) }) else { return nil }
        if let like, let same = volume.first(where: { $0.isAudio == like.isAudio }) { return same }
        return volume.first { ($0.progression ?? 0) > 0.001 } ?? volume.first
    }

    /// The spelling most of the books use — on a tie, the one the first in reading order uses.
    private static func displayName(_ books: [Book]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for name in books.compactMap({ $0.series?.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ""
    }
}
