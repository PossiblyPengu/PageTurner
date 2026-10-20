import Foundation

/// Which loose audio files belong to the same book. Better evidence beats the
/// folder everything happens to sit in: a shared album tag wins (it splits a
/// shared inbox and spans disc folders); sibling "CD 1"/"CD 2" folders merge
/// under their parent; and inside one folder the filename's stem ("Dune - 04"
/// → "dune") keeps a second book that landed in the same place from collapsing
/// into the first. Pure logic — checked on Linux.
enum AudioGrouping {
    /// A file up for import: where it is now, and its album tag ("" untagged).
    struct Item {
        let url: URL
        let album: String
    }

    /// The groups in first-seen order, each group's files in playing order —
    /// natural path order puts "…/CD 2/x" after "…/CD 1/x" and "ch2" before "ch10".
    static func groups(of items: [Item]) -> [[Item]] {
        let discParents = discParents(in: items)
        var buckets: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let key = key(of: item, discParents: discParents)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(item)
        }
        return order.map { key in
            (buckets[key] ?? []).sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        }
    }

    private static func key(of item: Item, discParents: Set<String>) -> String {
        let album = item.album
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        if !album.isEmpty { return "album|\(album)" }
        let dir = item.url.deletingLastPathComponent()
        if isDisc(dir.lastPathComponent), discParents.contains(dir.deletingLastPathComponent().path) {
            return "parent|\(dir.deletingLastPathComponent().path)"
        }
        let s = stem(item.url.lastPathComponent)
        return s.isEmpty ? "dir|\(dir.path)" : "stem|\(dir.path)|\(s)"
    }

    /// Parent folders holding more than one disc-named folder of this batch:
    /// "Book/CD 1" and "Book/CD 2" merge, a lone "CD 1" is taken at face value.
    private static func discParents(in items: [Item]) -> Set<String> {
        var seen: [String: Set<String>] = [:]
        for item in items {
            let dir = item.url.deletingLastPathComponent()
            guard isDisc(dir.lastPathComponent) else { continue }
            seen[dir.deletingLastPathComponent().path, default: []].insert(dir.lastPathComponent)
        }
        return Set(seen.filter { $0.value.count > 1 }.keys)
    }

    /// What a group's files spell together — the stem every file shares
    /// ("Dune - 01"…"Dune - 09" → "Dune"), when there is exactly one. Files
    /// whose stems are only numbering, that differ, or that name a generic
    /// word ("track 1" → "track") have nothing to say: nil, and the caller's
    /// other guesses (folder, tag, filename) decide.
    static func title(for urls: [URL]) -> String? {
        guard urls.count > 1 else { return nil }
        var shared: String?
        for url in urls {
            let s = stem(url.lastPathComponent)
            guard !s.isEmpty, shared == nil || shared == s else { return nil }
            shared = s
        }
        guard let s = shared,
              !Self.genericStems.contains(s) else { return nil }
        return s.capitalized
    }

    /// Stems that are a medium word, not a title — "track", "part", "audio".
    private static let genericStems: Set<String> = [
        "audio", "audiobook", "book", "cd", "chapter", "disc", "disk",
        "file", "part", "track", "trk", "vol", "volume",
    ]

    /// Folder names that hold whatever was dumped into them — never a title.
    private static let dumpFolders: Set<String> = [
        "inbox", "documents", "downloads", "desktop", "tmp", "temp",
    ]

    /// What the folder the files sit in says the book is called: the folder, or for "CD 1"/"CD 2" folders their
    /// common parent. Only when there are several files (a lone file in a folder is probably one of several in a
    /// shared folder: its own name says more) and the folder is one somebody named, not a dump ("Downloads", the
    /// share sheet's "Inbox").
    static func folderTitle(for urls: [URL]) -> String? {
        guard urls.count > 1 else { return nil }
        let dirs = Set(urls.map { $0.deletingLastPathComponent().path })
        let leaf: String
        if dirs.count == 1 {
            leaf = urls[0].deletingLastPathComponent().lastPathComponent
        } else {
            // tracks from sibling "CD n" folders take their common parent's
            let parents = Set(dirs.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            leaf = parents.count == 1 ? URL(fileURLWithPath: parents.first!).lastPathComponent : ""
        }
        guard !leaf.isEmpty, leaf != "/", !dumpFolders.contains(leaf.lowercased()) else { return nil }
        return leaf
    }

    /// "CD 1", "Disc 02", "Part 3" — one stretch of a book, not a book itself.
    static func isDisc(_ dirName: String) -> Bool {
        dirName.range(
            of: #"^(cd|disc|disk|part|pt)\s*[-_.]?\s*\d+[a-z]?$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the parts of one book share: the filename minus its extension and
    /// its numbering — leading "07 - ", trailing "- 04"/"_02", "CD 2", "part 03".
    /// Numbers that could be the title stay: digits glued to the word ("dune2")
    /// and digits after a bare space ("harry potter 2"). "" when nothing is
    /// left but numbering.
    static func stem(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension.lowercased()
        // a leading run of digits is a track number only when a name follows it
        s = s.replacingOccurrences(of: #"^\d+[\-_.\s]*(?=\p{L})"#, with: "", options: .regularExpression)
        var prev = ""
        while s != prev {
            prev = s
            // a part-word with its number: " cd 2", " pt4", "- part 03"
            s = s.replacingOccurrences(
                of: #"[-_.\s]*(cd|disc|disk|part|pt|chapter|ch|track|trk|bk|file|vol)\s*[-_.]?\s*\d+[a-z]?$"#,
                with: "", options: .regularExpression)
            // a separated run ending in digits: " - 01", " — 02", "_7"; a bare
            // space alone is not enough (that is how titles get numbered too)
            s = s.replacingOccurrences(
                of: #"[-_.\s]*[-_.]+[-_.\s]*\d+[a-z]?$"#, with: "", options: .regularExpression)
        }
        // a stem with no letters was never a name — the folder decides
        guard s.range(of: #"\p{L}"#, options: .regularExpression) != nil else { return "" }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
    }
}
