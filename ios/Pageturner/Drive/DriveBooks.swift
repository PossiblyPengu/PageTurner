import Foundation

/// Turning what is found in the Drive into books for the library, without downloading any of it: which files are one
/// book, what it is called, what its files will be named once they are down, and which of them are still to come.
/// Pure — checked off-device.
enum DriveBooks {
    /// A book to add to the library.
    struct Plan: Equatable {
        var title: String
        var isAudio: Bool
        var source: GoogleDrive.Source
        /// What each track is called, for an audiobook's chapter list.
        var trackTitles: [String]
    }

    /// A file found, and the Drive folders between it and the place being looked through ("Dune/CD 1").
    struct Found {
        var file: GoogleDrive.File
        var folder: String

        init(_ file: GoogleDrive.File, folder: String) {
            self.file = file
            self.folder = folder
        }
    }

    struct Result {
        /// New books, by title.
        var books: [Plan]
        /// Files that cannot be a book before they have been downloaded — a zip is unpacked, a text file made into an
        /// EPUB — so they come down when added.
        var direct: [Found]
        /// How many files were already in the library.
        var known: Int
    }

    /// What a book file can be while it is still in the Drive: the formats the reader opens as they are.
    static let lazyExtensions: Set<String> = ["epub", "pdf", "cbz"]

    /// Group `found` into books. `known`: the Drive file ids the library already holds — a file in one is not added again.
    static func plan(_ found: [Found], known: Set<String>) -> Result {
        var ebooks: [Plan] = []
        var direct: [Found] = []
        var audio: [Found] = []
        var already = 0
        for item in found {
            guard GoogleDrive.isImportable(item.file) else { continue }
            if known.contains(item.file.id) { already += 1; continue }
            let ext = item.file.fileExtension
            if Book.audioExtensions.contains(ext) {
                audio.append(item)
            } else if lazyExtensions.contains(ext) {
                let title = stem(of: item.file.name)
                ebooks.append(Plan(
                    title: title, isAudio: false,
                    source: GoogleDrive.Source(parts: [GoogleDrive.FileRef(item.file)], guessedTitle: title),
                    trackTitles: []))
            } else {
                direct.append(item)
            }
        }

        // audio files group the way an import from the Files app does: sibling "CD n" folders merge, and a second
        // book's different file-name stem in the same folder stays a book of its own
        var byPath: [String: [Found]] = [:]
        var items: [AudioGrouping.Item] = []
        for item in audio {
            let path = "/" + (item.folder.isEmpty ? item.file.name : item.folder + "/" + item.file.name)
            byPath[path, default: []].append(item)
            items.append(AudioGrouping.Item(url: URL(fileURLWithPath: path), album: ""))
        }
        var audiobooks: [Plan] = []
        for group in AudioGrouping.groups(of: items) {
            var files: [Found] = []
            for item in group {
                if var list = byPath[item.url.path], !list.isEmpty {
                    files.append(list.removeFirst())
                    byPath[item.url.path] = list
                }
            }
            guard !files.isEmpty else { continue }
            let urls = group.map(\.url)
            let title = AudioGrouping.folderTitle(for: urls)
                ?? AudioGrouping.title(for: urls)
                ?? stem(of: files[0].file.name)
            let folders = Set(files.map(\.folder))
            // parts from more than one folder need their folder in the chapter list: "01" in "CD 1" and "01" in "CD 2"
            // are both real tracks
            let tracks = files.map { found -> String in
                let name = stem(of: found.file.name)
                guard folders.count > 1 else { return name }
                let leaf = found.folder.split(separator: "/").last.map(String.init) ?? ""
                return leaf.isEmpty ? name : "\(leaf) — \(name)"
            }
            audiobooks.append(Plan(
                title: title, isAudio: true,
                source: GoogleDrive.Source(parts: files.map { GoogleDrive.FileRef($0.file) }, guessedTitle: title),
                trackTitles: tracks))
        }

        let books = (ebooks + audiobooks).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Result(books: books, direct: direct, known: already)
    }

    private static func stem(of name: String) -> String {
        let stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? name : stem
    }

    // MARK: Files on this device

    /// The name a part is given in the Books folder once it is down: a book's one file is `<id>.<ext>`, an audiobook's
    /// parts `<id>-<n>.<ext>` — as the importer names them.
    static func localName(book: UUID, index: Int, part: GoogleDrive.FileRef, audio: Bool) -> String {
        let ext = (part.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return audio ? "\(book.uuidString)-\(index)" : book.uuidString }
        return audio ? "\(book.uuidString)-\(index).\(ext)" : "\(book.uuidString).\(ext)"
    }

    /// The parts still to come down: those whose file is not on the device at the size Drive gave it. `size` says how
    /// big the file called `name` is here, nil when there is none.
    static func pending(_ source: GoogleDrive.Source, names: [String], size: (String) -> Int64?) -> [Int] {
        source.parts.indices.filter { index in
            guard index < names.count, let have = size(names[index]) else { return true }
            if let expected = source.parts[index].size, expected != have { return true }
            return false
        }
    }

    /// How much of what is wanted has come: 0…1, nil when nothing is known about the size.
    static func fraction(received: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}
