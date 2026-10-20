import AVFoundation
import Foundation
import ImageIO
import ReadiumShared
import ReadiumZIPFoundation
import SwiftUI
import UIKit

struct Bookmark: Identifiable, Codable, Hashable {
    let id: UUID
    /// Chapter/excerpt shown in the list.
    var title: String
    /// Position, as a Readium `Locator` in JSON.
    var locatorJSON: String
    /// 0…1 through the whole book when saved.
    var progression: Double?
    var createdAt: Date

    init(id: UUID = UUID(), title: String, locatorJSON: String, progression: Double?, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.locatorJSON = locatorJSON
        self.progression = progression
        self.createdAt = createdAt
    }
}

/// Dates in library.json and in backups. The catalogue is written as seconds since
/// 1970 (and the web app's backups as milliseconds), but earlier builds wrote and
/// read Foundation's default — seconds since 2001 — and a mismatch between the two
/// moved every date forward 31 years with each save.
enum StoredDate {
    /// 2001-01-01 minus 1970-01-01, in seconds: how far one mismatched save moves a date.
    private static let referenceGap: TimeInterval = 978_307_200

    static func read(_ raw: Double?, now: Date = Date()) -> Date? {
        guard let raw, raw.isFinite else { return nil }
        // seconds now ≈ 1.7e9, milliseconds ≈ 1.7e12, so 1e11 cleanly separates them
        var date: Date
        if raw > 1e11 {
            date = Date(timeIntervalSince1970: raw / 1000)
        } else if raw >= 946_684_800 {
            // 2000-01-01 in 1970-based seconds: anything under it can't be a real
            // 1970-based date, so it is read as an early build's 2001-based one
            date = Date(timeIntervalSince1970: raw)
        } else if raw > 0 {
            date = Date(timeIntervalSinceReferenceDate: raw)
        } else {
            return nil
        }
        // nothing in the library was made in the future — a date that is was moved on by
        // whole gaps, so walk it back
        let limit = now.addingTimeInterval(86_400)
        var walks = 0
        while date > limit, walks < 12 {
            date = date.addingTimeInterval(-referenceGap)
            walks += 1
        }
        return date > limit ? nil : date
    }
}

/// A place marked in an audiobook.
struct AudioClip: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Seconds from the start of the book.
    var time: TimeInterval
    var chapter: String?
    var note = ""
    /// Seconds since 1970.
    var created: Double = Date().timeIntervalSince1970

    var createdAt: Date { Date(timeIntervalSince1970: created) }
}

struct Book: Identifiable, Codable, Hashable {
    /// Extensions AVPlayer handles directly (m4b/m4a are MPEG-4 audio).
    static let audioExtensions: Set<String> = [
        "m4b", "m4a", "mp3", "aac", "wav", "flac", "ogg", "oga", "opus", "caf",
    ]

    let id: UUID
    var title: String
    var author: String
    /// File name inside the Books folder — the first track for audiobooks.
    var fileName: String
    /// All tracks, in play order. Equals `[fileName]` for single-file books.
    var fileNames: [String] = []
    /// Original track display names (audiobooks import as `<id>-<n>.<ext>`,
    /// so the source basenames are kept here for the chapter picker).
    var trackTitles: [String] = []
    var addedAt: Date
    var lastOpenedAt: Date?
    /// Reading position, as a Readium `Locator` in JSON.
    var locatorJSON: String?
    /// Audiobook position in seconds from the start of the first track.
    var audioPosition: TimeInterval?
    /// 0…1 through the whole book.
    var progression: Double?
    var bookmarks: [Bookmark] = []
    var highlights: [Highlight] = []
    /// The BookMaster shelf row this book is pinned to, once a push has made one.
    var bookmasterId: String?
    /// What BookMaster's shelf says about this book (status, rating, how far
    /// it thinks you are, whether it is queued up next) — display only.
    var bmStatus: String?
    var bmRating: Int?
    var bmRemotePercent: Double?
    var bmUpNext: Bool?
    /// A blurb for the detail page — from the EPUB's own metadata or an online lookup.
    var bookDescription: String?
    var year: String?
    var isbn: String?
    /// Open Library work id ("OL45804W") — what BookMaster keeps on its catalogue rows.
    var openLibraryId: String?
    /// A real page count, learned on open — a PDF's pages, a page-listed
    /// EPUB's print pages. Pushed to BookMaster as `total_pages` so the
    /// percent can be said in pages there.
    var pages: Int?
    /// Names of the shelves this book is on.
    var collections: [String] = []
    /// When the "pick up where BookMaster has you" offer was last declined for this book.
    var resumeDismissedAt: Date?
    /// The series the book belongs to and its place in it, when the file says.
    var series: String?
    var seriesIndex: Double?
    /// The speed this audiobook is played at, kept per book.
    var audioRate: Double?
    /// Places marked in an audiobook, with an optional note.
    var audioClips: [AudioClip] = []
    /// Words and phrases saved from the book to look up later.
    var words: [SavedWord] = []
    /// Set when the book was added from Google Drive: the Drive files it is made of. Its files come down when asked
    /// for (`DriveDownloads`), and the book stays in the library, with its place, whether they are on the device or not.
    var drive: GoogleDrive.Source?

    var ext: String { fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? "" }
    /// The local name keeps the file's extension, except Drive parts whose Drive name
    /// had none — then the parts' own names say whether the book is audio.
    var isAudio: Bool {
        Self.audioExtensions.contains(ext)
            || (drive?.parts.contains { Self.audioExtensions.contains(($0.name as NSString).pathExtension.lowercased()) } ?? false)
    }
}

/// A word or short phrase saved from a book, with the line it was found in.
struct SavedWord: Identifiable, Codable, Hashable {
    let id: UUID
    var word: String
    /// A little of the text either side of it, cut at word edges.
    var context: String?
    var chapter: String?
    var createdAt: Date

    init(id: UUID = UUID(), word: String, context: String? = nil, chapter: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.word = word
        self.context = context
        self.chapter = chapter
        self.createdAt = createdAt
    }

    /// A selection tidied into a word: spaces collapsed, quotes and stops at the edges dropped (the ones inside, as
    /// in "don't", stay). Nil when nothing is left or it is longer than a short phrase — a sentence is a highlight.
    static func clean(_ selection: String) -> String? {
        let edge = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        let trimmed = selection.trimmingCharacters(in: edge)
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        let word = parts.joined(separator: " ")
        return word.count <= 48 ? word : nil
    }

    /// "…the weather had turned sullen and grey…": up to `reach` characters either side, started and ended on whole
    /// words, with an ellipsis only where text was cut. Nil when there is nothing around the word.
    static func context(before: String?, word: String, after: String?, reach: Int = 60) -> String? {
        func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let head = collapse(before ?? ""), tail = collapse(after ?? "")
        guard !head.isEmpty || !tail.isEmpty else { return nil }

        // when text was cut, the partial word at the cut goes with it
        var lead = String(head.suffix(reach))
        let cutLead = head.count > reach
        if cutLead { lead = lead.firstIndex(of: " ").map { String(lead[lead.index(after: $0)...]) } ?? "" }
        var rest = String(tail.prefix(reach))
        let cutRest = tail.count > reach
        if cutRest { rest = rest.lastIndex(of: " ").map { String(rest[..<$0]) } ?? "" }

        // a space joins the word to its neighbours only where the page had one (not after an opening quote)
        let spaceBefore = before?.last?.isWhitespace ?? true
        let spaceAfter = after?.first?.isWhitespace ?? true
        return (cutLead ? "…" : "")
            + (lead.isEmpty ? "" : lead + (spaceBefore ? " " : ""))
            + word
            + (rest.isEmpty ? "" : (spaceAfter ? " " : "") + rest)
            + (cutRest ? "…" : "")
    }
}

struct Highlight: Identifiable, Codable, Hashable {
    let id: UUID
    /// Position + selected text, as a Readium `Locator` in JSON.
    var locatorJSON: String
    /// The selected text, shown in the list.
    var text: String
    var createdAt: Date
    /// A `HighlightColor` raw value. Nil is the standard yellow — what a highlight
    /// made before colours existed has.
    var color: String?
    /// The reader's own note on the passage.
    var note: String?
    /// The chapter it was in and how far through the book (0…1), noted when it
    /// was made — for the export, and to list highlights in reading order.
    var chapter: String?
    var progression: Double?
    /// Whether it has been sent to BookMaster as a quote — so "send new highlights" never sends one twice.
    var quoted: Bool?

    init(
        id: UUID = UUID(), locatorJSON: String, text: String, createdAt: Date = Date(),
        color: String? = nil, note: String? = nil, chapter: String? = nil, progression: Double? = nil,
        quoted: Bool? = nil
    ) {
        self.id = id
        self.locatorJSON = locatorJSON
        self.text = text
        self.createdAt = createdAt
        self.color = color
        self.note = note
        self.chapter = chapter
        self.progression = progression
        self.quoted = quoted
    }
}

extension Bookmark {
    /// `createdAt` is read the way the catalogue's other dates are — the default
    /// decoder would take seconds since 1970 as seconds since 2001.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        locatorJSON = try c.decode(String.self, forKey: .locatorJSON)
        progression = try c.decodeIfPresent(Double.self, forKey: .progression)
        createdAt = StoredDate.read(try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? Date()
    }
}

extension Highlight {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        locatorJSON = try c.decode(String.self, forKey: .locatorJSON)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = StoredDate.read(try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? Date()
        color = try c.decodeIfPresent(String.self, forKey: .color)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        chapter = try c.decodeIfPresent(String.self, forKey: .chapter)
        progression = try c.decodeIfPresent(Double.self, forKey: .progression)
        quoted = try c.decodeIfPresent(Bool.self, forKey: .quoted)
    }
}

extension Book {
    /// Older library.json files predate `bookmarks`/`fileNames`/`audioPosition`
    /// — decode leniently so the catalogue keeps loading on the missing keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        fileName = try c.decode(String.self, forKey: .fileName)
        func date(_ key: CodingKeys) -> Date? {
            StoredDate.read(try? c.decodeIfPresent(Double.self, forKey: key))
        }
        addedAt = date(.addedAt) ?? Date()
        lastOpenedAt = date(.lastOpenedAt)
        locatorJSON = try c.decodeIfPresent(String.self, forKey: .locatorJSON)
        audioPosition = try c.decodeIfPresent(TimeInterval.self, forKey: .audioPosition)
        progression = try c.decodeIfPresent(Double.self, forKey: .progression)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? [fileName]
        trackTitles = try c.decodeIfPresent([String].self, forKey: .trackTitles) ?? []
        bookmasterId = try c.decodeIfPresent(String.self, forKey: .bookmasterId)
        bmStatus = try c.decodeIfPresent(String.self, forKey: .bmStatus)
        bmRating = try c.decodeIfPresent(Int.self, forKey: .bmRating)
        bmRemotePercent = try c.decodeIfPresent(Double.self, forKey: .bmRemotePercent)
        bmUpNext = try c.decodeIfPresent(Bool.self, forKey: .bmUpNext)
        bookDescription = try c.decodeIfPresent(String.self, forKey: .bookDescription)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        openLibraryId = try c.decodeIfPresent(String.self, forKey: .openLibraryId)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        collections = try c.decodeIfPresent([String].self, forKey: .collections) ?? []
        resumeDismissedAt = date(.resumeDismissedAt)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesIndex = try c.decodeIfPresent(Double.self, forKey: .seriesIndex)
        audioRate = try c.decodeIfPresent(Double.self, forKey: .audioRate)
        audioClips = (try? c.decodeIfPresent([AudioClip].self, forKey: .audioClips)) ?? []
        words = (try? c.decodeIfPresent([SavedWord].self, forKey: .words)) ?? []
        drive = try? c.decodeIfPresent(GoogleDrive.Source.self, forKey: .drive)
    }

    /// How a BookMaster push names this book.
    var bookMasterRef: BMBookRef {
        BMBookRef(title: title, author: sendableAuthor(author), isbn: isbn,
                  openLibraryId: openLibraryId, userBookId: bookmasterId,
                  bookDescription: bookDescription, publishedYear: year.flatMap(Int.init),
                  totalPages: pages)
    }
}

extension Book {
    /// The title as a library files it: "The Hobbit" under H (an article alone, or the whole title, stays).
    var sortTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        for article in ["the ", "an ", "a "] where lower.hasPrefix(article) && t.count > article.count + 1 {
            return String(t.dropFirst(article.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// The author as a library files it, by last name: "Frank Herbert" as "Herbert, Frank"; "A & B" under A;
    /// "Herbert, Frank" as it is.
    var sortAuthor: String {
        var first = author
            .replacingOccurrences(of: " and ", with: "&")
            .split(whereSeparator: { $0 == "&" || $0 == ";" })
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return first }
        if let comma = first.firstIndex(of: ",") {
            // "Herbert, Frank" is filed already; "Frank Herbert, Brian Herbert" is a list — the first author's
            let head = first[..<comma].trimmingCharacters(in: .whitespaces)
            if !head.contains(" ") { return first }
            first = head
        }
        var words = first.split(separator: " ").map(String.init)
        let suffixes: Set<String> = ["jr.", "jr", "sr.", "sr", "ii", "iii", "iv", "phd", "ph.d.", "md", "m.d."]
        while words.count > 2, suffixes.contains(words[words.count - 1].lowercased()) { words.removeLast() }
        guard words.count >= 2 else { return first }
        // the surname is the last word, with the particles that belong to it ("Le Guin", "van Gogh")
        var cut = words.count - 1
        let particles: Set<String> = ["le", "la", "de", "del", "della", "di", "da", "du", "van", "von", "der", "den", "ten", "ter", "st.", "al", "el"]
        while cut > 1, particles.contains(words[cut - 1].lowercased()) { cut -= 1 }
        return "\(words[cut...].joined(separator: " ")), \(words[..<cut].joined(separator: " "))"
    }
}

/// The library: book files in Documents/Books (visible in the Files app),
/// covers and the catalogue in Application Support.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// Shelves (the web app's "collections") in the order they were made.
    @Published private(set) var shelves: [String] = UserDefaults.standard.stringArray(forKey: "shelves") ?? []
    @Published var importing = false
    /// Books whose file is no longer on the device (deleted in the Files app): marked, and they do not open.
    @Published private(set) var missing: Set<UUID> = []
    /// Books from Google Drive whose files have not (all) come down: in the library, waiting to be downloaded.
    @Published private(set) var inCloud: Set<UUID> = []
    @Published var lastError: String?

    private let fm = FileManager.default
    private let booksDir: URL
    private let coversDir: URL
    private let catalogueURL: URL

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        booksDir = docs.appendingPathComponent("Books", isDirectory: true)
        coversDir = support.appendingPathComponent("Covers", isDirectory: true)
        catalogueURL = support.appendingPathComponent("library.json")
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: catalogueURL) {
            // element-wise: one bad record must not empty the library (and the
            // next save then overwrite the catalogue with nothing)
            struct Lossy: Decodable {
                let book: Book?
                init(from decoder: Decoder) throws { book = try? Book(from: decoder) }
            }
            if let list = try? JSONDecoder().decode([Lossy].self, from: data) {
                let good = list.compactMap(\.book)
                if good.count != list.count {
                    let backup = support.appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                    try? data.write(to: backup, options: .atomic)
                    Log.error("library", "\(list.count - good.count) of \(list.count) books could not be read; original kept as \(backup.lastPathComponent)")
                }
                books = good
            } else {
                let backup = support.appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: backup, options: .atomic)
                Log.error("library", "library.json could not be read; original kept as \(backup.lastPathComponent)")
            }
        }
        refreshMissing()
    }

    /// Look for books whose file has gone, off the main thread — at launch and when the app returns. A book from
    /// Google Drive without its files is not missing: it is waiting to be downloaded (`inCloud`).
    func refreshMissing() {
        let snapshot = books.map { (id: $0.id, urls: fileURLs(for: $0), cloud: $0.drive != nil) }
        Task {
            let (gone, cloud) = await Task.detached(priority: .utility) { () -> (Set<UUID>, Set<UUID>) in
                let fm = FileManager.default
                var gone = Set<UUID>(), cloud = Set<UUID>()
                for entry in snapshot where entry.urls.contains(where: { !fm.fileExists(atPath: $0.path) }) {
                    if entry.cloud { cloud.insert(entry.id) } else { gone.insert(entry.id) }
                }
                return (gone, cloud)
            }.value
            // only the books that were looked at: one added while this ran (a Drive sync) is not in the answer, and
            // must keep what it was given
            let looked = Set(snapshot.map(\.id))
            let newMissing = missing.subtracting(looked).union(gone)
            let newCloud = inCloud.subtracting(looked).union(cloud)
            if missing != newMissing { missing = newMissing }
            if inCloud != newCloud { inCloud = newCloud }
        }
    }

    /// The book most recently opened that isn't finished.
    var continueBook: Book? {
        books
            .filter { ($0.progression ?? 0) > 0.001 && ($0.progression ?? 0) < 0.995 }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    /// The Books folder (in Documents, visible in the Files app) — where a Drive download is put.
    nonisolated static var booksFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Books", isDirectory: true)
    }

    /// How big the file called `name` in the Books folder is, nil when there is none.
    func localSize(of name: String) -> Int64? {
        Self.fileSize(booksDir.appendingPathComponent(name)).map(Int64.init)
    }

    func fileURL(for book: Book) -> URL { booksDir.appendingPathComponent(book.fileName) }
    func fileURLs(for book: Book) -> [URL] {
        let names = book.fileNames.isEmpty ? [book.fileName] : book.fileNames
        return names.map { booksDir.appendingPathComponent($0) }
    }
    func coverURL(for book: Book) -> URL { coversDir.appendingPathComponent(book.id.uuidString + ".jpg") }

    func cover(for book: Book) -> UIImage? {
        let path = coverURL(for: book).path
        guard fm.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }

    /// Cell-sized covers, decoded once and remembered: the grid asks on every
    /// layout, and a 2400px EPUB jacket should not be decoded at full size for
    /// a 120pt cell. ImageIO makes the thumbnail from the file directly, so the
    /// big decode never happens.
    private let coverThumbs = NSCache<NSString, UIImage>()

    func coverThumbnail(for book: Book, maxPixels: Int) -> UIImage? {
        let key = "\(book.id.uuidString)-\(maxPixels)" as NSString
        if let hit = coverThumbs.object(forKey: key) { return hit }
        guard fm.fileExists(atPath: coverURL(for: book).path),
              let source = CGImageSourceCreateWithURL(coverURL(for: book) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return cover(for: book) }
        let image = UIImage(cgImage: cg)
        coverThumbs.setObject(image, forKey: key)
        return image
    }

    // MARK: - Import

    /// Audio files group into audiobooks by what they are, not just where they
    /// landed: a shared album tag wins, sibling "CD n" folders merge under
    /// their parent, and inside a folder a different name stem stays a
    /// different book (AudioGrouping). Tracks play in natural path order so
    /// "ch2" comes before "ch10". Ebooks import one per file.
    enum ImportError: LocalizedError {
        case notAnArchive, looksLikeBackup, nothingToImport, emptyText, duplicate(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: return "That zip file couldn’t be opened."
            case .looksLikeBackup: return "That looks like a Pageturner backup — restore it from Settings → Backup → Restore Backup."
            case .nothingToImport: return "There were no books, comics or audio files inside."
            case .emptyText: return "There was no text in that file."
            case let .duplicate(title): return "“\(title)” is already in your library."
            }
        }
    }

    /// What a zip may carry. HTML and text are left out on purpose: a zip of a
    /// website or a folder of notes shouldn't become hundreds of "books".
    private static let archiveExtensions = Set(["epub", "pdf", "cbz"]).union(Book.audioExtensions)

    /// "Open in" and share-sheet deliveries arrive one URL at a time, back to
    /// back — hold the batch for a beat so a multi-part book lands as one.
    private var pendingURLs: [URL] = []
    /// Only the wait is ever cancelled; a batch that has started always finishes,
    /// and the next one starts after it.
    private var debounce: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var activeBatches = 0
    /// Picked folders stay open for the whole batch: their children only keep
    /// access while the folder's own scope is held.
    private var scopedRoots: [URL] = []

    func importFiles(_ urls: [URL]) async {
        pendingURLs.append(contentsOf: urls)
        importing = true
        debounce?.cancel()
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: .milliseconds(800)) }
        debounce = sleeper
        await sleeper.value
        guard !sleeper.isCancelled else { return }

        let previous = running
        activeBatches += 1
        let work = Task {
            await previous?.value
            defer {
                activeBatches -= 1
                importing = activeBatches > 0 || !pendingURLs.isEmpty
            }
            let batch = pendingURLs
            pendingURLs = []
            guard !batch.isEmpty else { return }
            var failures: [String] = []
            await importBatch(batch, failures: &failures, inArchive: false)
            // files delivered to Documents/Inbox (AirDrop, Mail, "Open in") are copies the app made its own of
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let inbox = docs.appendingPathComponent("Inbox").resolvingSymlinksInPath().path + "/"
            for url in batch where url.resolvingSymlinksInPath().path.hasPrefix(inbox) {
                try? fm.removeItem(at: url)
            }
            for root in scopedRoots { root.stopAccessingSecurityScopedResource() }
            scopedRoots = []
            if !failures.isEmpty {
                lastError = failures.joined(separator: "\n")
                for failure in failures { Log.error("import", failure) }
            }
        }
        running = work
        await work.value
    }

    /// A picked folder means its contents — folders and all. Files inside it
    /// keep their folders, so the audio grouping below still applies. The
    /// folder's security scope stays open (`scopedRoots`) until the batch ends.
    private func expanded(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir, let walker = fm.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            {
                for case let file as URL in walker {
                    // the walker also yields the subfolders themselves; only files are books
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                    out.append(file)
                }
            }
            if scoped {
                if isDir { scopedRoots.append(url) } else { url.stopAccessingSecurityScopedResource() }
            }
            if !isDir { out.append(url) }
        }
        return out
    }

    private func importBatch(_ urls: [URL], failures: inout [String], inArchive: Bool) async {
        var audio: [URL] = []
        for url in expanded(urls) {
            let ext = url.pathExtension.lowercased()
            if Book.audioExtensions.contains(ext) {
                audio.append(url)
            } else if ext == "zip", !inArchive {
                do { try await importArchive(url, failures: &failures) } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            } else if let format = TextBook.format(forExtension: ext) {
                do { try await importTextBook(url, format: format) } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                do { try await importFile(url) } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        // group by what the files are, not just where they landed: an album
        // tag wins, disc folders merge, a second book's different stem splits
        var items: [AudioGrouping.Item] = []
        for url in audio {
            items.append(.init(url: url, album: audio.count > 1 ? await albumTag(url) : ""))
        }
        for group in AudioGrouping.groups(of: items) {
            do { try await importAudiobook(group.map(\.url)) } catch {
                failures.append("\(group.count) audio files: \(error.localizedDescription)")
            }
        }
    }

    /// The album tag of one audio file, "" when it has none — read for the
    /// grouping decision, so a mixed folder or an inbox of parts splits right.
    private func albumTag(_ url: URL) async -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        return metadata.first { $0.commonKey == .commonKeyAlbumName }?.stringValue ?? ""
    }

    /// A zip of books — a folder of audiobook parts, a pile of EPUBs — unpacked
    /// and imported. Folders inside it stay folders, so each audiobook
    /// directory becomes one book — and sibling "CD n" folders merge into one.
    private func importArchive(_ source: URL, failures: inout [String]) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let archive = try? await Archive(url: source, accessMode: .read) else {
            throw ImportError.notAnArchive
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("unzip-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var extracted: [URL] = []
        let root = tmp.standardizedFileURL.path + "/"
        for entry in try await archive.entries() where entry.type == .file {
            let path = entry.path
            if path == "data.json" { throw ImportError.looksLikeBackup }
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard Self.archiveExtensions.contains(ext), !name.hasPrefix("."), !path.hasPrefix("__MACOSX/") else { continue }
            // zip-slip: a crafted "../" entry must not escape the staging folder
            let out = tmp.appendingPathComponent(path)
            guard out.standardizedFileURL.path.hasPrefix(root) else { continue }
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? await archive.extract(entry, to: out)) != nil { extracted.append(out) }
        }
        guard !extracted.isEmpty else { throw ImportError.nothingToImport }
        await importBatch(extracted, failures: &failures, inArchive: true)
    }

    /// Plain text, Markdown or HTML: rebuilt as an EPUB (chapters found, text
    /// un-wrapped) so it reads like any other book, then imported as one.
    private func importTextBook(_ source: URL, format: TextBook.Format) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: source) }.value
        let fallback = source.deletingPathExtension().lastPathComponent
        // a long book takes a moment — keep it off the main actor
        let converted = await Task.detached(priority: .userInitiated) {
            TextBook.convert(data, format: format, fallbackTitle: fallback)
        }.value
        guard let converted else { throw ImportError.emptyText }

        let id = UUID()
        let fileName = "\(id.uuidString).epub"
        try converted.epub.write(to: booksDir.appendingPathComponent(fileName), options: .atomic)
        try await register(id: id, fileName: fileName, fallbackTitle: converted.title)
    }

    private func importAudiobook(_ sources: [URL]) async throws {
        // full paths, not basenames: sibling "CD 1"/"CD 2" parts can share a
        // name, and only their folders keep them apart and in order
        let sorted = sources.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let id = UUID()
        var fileNames: [String] = []
        do {
            for source in sorted {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let ext = source.pathExtension.lowercased()
                let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString)-\(fileNames.count).\(ext)"
                let destination = booksDir.appendingPathComponent(fileName)
                // a long audiobook is hundreds of MB — keep the copy off the main actor
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
                fileNames.append(fileName)
            }
        } catch {
            // a partial copy would orphan files nobody references
            for name in fileNames {
                try? fm.removeItem(at: booksDir.appendingPathComponent(name))
            }
            throw error
        }

        var book = Book(
            id: id,
            title: sorted[0].deletingPathExtension().lastPathComponent,
            author: "",
            fileName: fileNames[0],
            fileNames: fileNames,
            addedAt: Date()
        )
        // parts from more than one folder need their folder in the chapter
        // list — "01" in "CD 1" and "01" in "CD 2" are both real tracks
        let dirs = Set(sorted.map { $0.deletingLastPathComponent().path })
        book.trackTitles = sorted.map {
            let name = $0.deletingPathExtension().lastPathComponent
            return dirs.count > 1 ? "\($0.deletingLastPathComponent().lastPathComponent) — \(name)" : name
        }
        // Title priority: album metadata → shared folder name → track title →
        // filename. Track-1 title is often a chapter name ("Chapter 1"), which
        // is worse than the folder the files came from.
        let asset = AVURLAsset(url: fileURL(for: book))
        let metadata = (try? await asset.load(.metadata)) ?? []
        func meta(_ key: AVMetadataKey) -> AVMetadataItem? {
            metadata.first { $0.commonKey == key }
        }
        // the folder the files sit in (see `AudioGrouping.folderTitle`)
        let dirTitle = AudioGrouping.folderTitle(for: sorted)
        if let album = meta(.commonKeyAlbumName)?.stringValue, !album.isEmpty {
            book.title = album
        } else if let dirTitle {
            book.title = dirTitle
        } else if let stemTitle = AudioGrouping.title(for: sorted) {
            book.title = stemTitle
        } else if let name = meta(.commonKeyTitle)?.stringValue, !name.isEmpty {
            book.title = name
        }
        if let name = meta(.commonKeyArtist)?.stringValue {
            book.author = name
        }
        if let data = meta(.commonKeyArtwork)?.dataValue,
           let image = UIImage(data: data),
           let jpeg = image.jpegData(compressionQuality: 0.85)
        {
            try? jpeg.write(to: coverURL(for: book))
        }
        books.insert(book, at: 0)
        save()
    }

    private func importFile(_ source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let ext = source.pathExtension.lowercased()
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destination = booksDir.appendingPathComponent(fileName)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        try await register(id: id, fileName: fileName, fallbackTitle: source.deletingPathExtension().lastPathComponent)
    }

    /// Open a copied file with Readium for its title, author and cover, and put
    /// it on the shelf. A file Readium can't open is removed again.
    private func register(id: UUID, fileName: String, fallbackTitle: String) async throws {
        let dest = booksDir.appendingPathComponent(fileName)
        var book = Book(
            id: id,
            title: fallbackTitle,
            author: "",
            fileName: fileName,
            fileNames: [fileName],
            addedAt: Date()
        )
        do {
            try await readDetails(of: &book, at: dest)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        // the same file twice ("Open in" twice, the watched folder plus a manual import) is one book
        if let size = Self.fileSize(dest),
           books.contains(where: {
               $0.fileNames.count <= 1 && $0.title == book.title && $0.author == book.author
                   && Self.fileSize(fileURL(for: $0)) == size
           })
        {
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: coverURL(for: book))
            throw ImportError.duplicate(book.title)
        }
        books.insert(book, at: 0)
        save()
    }

    /// What Readium finds in a book file: its title, author, blurb, year, ISBN and series go onto `book`, and its cover
    /// is written to the book's cover file. Throws when the file cannot be opened.
    private func readDetails(of book: inout Book, at url: URL) async throws {
        let publication = try await Readium.shared.open(url: url)
        if let title = publication.metadata.title, !title.isEmpty { book.title = title }
        // " & ", not ", ": a comma reads as "Last, First" to BookMaster
        book.author = publication.metadata.authors.map(\.name).joined(separator: " & ")
        if let blurb = publication.metadata.description, !blurb.isEmpty {
            let text = BookText.plain(fromHTML: blurb)
            if !text.isEmpty { book.bookDescription = text }
        }
        if let published = publication.metadata.published {
            // UTC: a date at midnight UTC must not read as the previous year in the Americas
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            book.year = String(calendar.component(.year, from: published))
        }
        if let identifier = publication.metadata.identifier, let isbn = ISBN.normalize(identifier) {
            book.isbn = isbn
        }
        if let series = publication.metadata.belongsToSeries.first, !series.name.isEmpty {
            book.series = series.name
            book.seriesIndex = series.position
        }
        if let image = try? await publication.cover().get(),
           let jpeg = image.jpegData(compressionQuality: 0.85)
        {
            try? jpeg.write(to: coverURL(for: book))
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // MARK: - Changes

    /// Save a book the reader or player changed. Those hold their own copy of
    /// the book, so the BookMaster fields — which only a push reply or a shelf
    /// pull may change — are always kept from the stored one; writing back a
    /// stale copy must not undo them. Use `updateBookMaster` to change them.
    func update(_ book: Book) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        var incoming = book
        incoming.bookmasterId = books[i].bookmasterId
        incoming.bmStatus = books[i].bmStatus
        incoming.bmRating = books[i].bmRating
        incoming.bmRemotePercent = books[i].bmRemotePercent
        incoming.bmUpNext = books[i].bmUpNext
        books[i] = incoming
        save()
    }

    /// The answer to "BookMaster has you at N% — jump there?": take its place
    /// (`fraction`) or, with nil, stay where this device is.
    func answerResume(_ id: UUID, fraction: Double?) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        var book = books[i]
        if let fraction { ResumeOffer.accept(&book, fraction: fraction) } else { ResumeOffer.decline(&book) }
        update(book)
    }

    /// Change one book's record as it is stored right now. This is what a player or reader should
    /// save a position with: writing back its own older copy of the whole `Book` would undo an
    /// edit made meanwhile (a title, a shelf, a note).
    func mutate(_ id: UUID, _ change: (inout Book) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        var book = books[i]
        change(&book)
        guard book != books[i] else { return }
        books[i] = book
        save()
    }

    /// Change only the BookMaster fields of one book.
    func updateBookMaster(_ id: UUID, _ change: (inout Book) -> Void) {
        mutate(id, change)
    }

    /// Apply a whole shelf pull in one write.
    func applyShelf(_ changes: [(UUID, (inout Book) -> Void)]) {
        var changed = false
        for (id, change) in changes {
            guard let i = books.firstIndex(where: { $0.id == id }) else { continue }
            var book = books[i]
            change(&book)
            if book != books[i] { books[i] = book; changed = true }
        }
        if changed { save() }
    }

    // MARK: - Books from Google Drive

    /// The Drive files the library already holds a book for, downloaded or not.
    var driveFileIDs: Set<String> {
        Set(books.flatMap { $0.drive?.parts.map(\.id) ?? [] })
    }

    /// Put books found in the Drive on the shelf without downloading anything: each is a book with its title, ready
    /// to be downloaded when the reader asks. The first of `plans` ends up on top.
    @discardableResult
    func addFromDrive(_ plans: [DriveBooks.Plan]) -> [Book] {
        let now = Date()
        var added: [Book] = []
        for (n, plan) in plans.enumerated() where !plan.source.parts.isEmpty {
            if let have = existing(for: plan) {
                if have.exact { link(have.book.id, to: plan.source) }
                continue
            }
            let id = UUID()
            let names = plan.source.parts.enumerated().map {
                DriveBooks.localName(book: id, index: $0.offset, part: $0.element, audio: plan.isAudio)
            }
            var book = Book(
                id: id, title: plan.title, author: "", fileName: names[0], fileNames: names,
                addedAt: now.addingTimeInterval(-Double(n) * 0.001))
            book.trackTitles = plan.trackTitles
            book.drive = plan.source
            added.append(book)
        }
        guard !added.isEmpty else { return [] }
        books.insert(contentsOf: added, at: 0)
        inCloud.formUnion(added.map(\.id))
        save()
        return added
    }

    /// The book the library already has for this one, however it got here (the Files app, an earlier Drive download): the
    /// same size of file, or the same title — taking a name like "David Wong - John Dies at the End" as the title alone,
    /// too. `exact`: the files are the very same size, so the copy on the phone *is* the Drive file.
    func existing(for plan: DriveBooks.Plan) -> (book: Book, exact: Bool)? {
        let size = plan.source.bytes
        var titles: Set<String> = [Self.fold(plan.title)]
        let (left, right) = MetadataLookup.splitName(plan.title)
        if !right.isEmpty { titles.insert(Self.fold(left)); titles.insert(Self.fold(right)) }
        titles.remove("")
        var byTitle: Book?
        for book in books where book.isAudio == plan.isAudio {
            if size > 0, !inCloud.contains(book.id) {
                let have = fileURLs(for: book).reduce(Int64(0)) { $0 + (Self.fileSize($1).map(Int64.init) ?? 0) }
                if have == size { return (book, true) }
            }
            if byTitle == nil, titles.contains(Self.fold(book.title)) { byTitle = book }
        }
        return byTitle.map { ($0, false) }
    }

    func holds(_ plan: DriveBooks.Plan) -> Bool { existing(for: plan) != nil }

    /// A book already in the library turns out to be this Drive file: it keeps its place and notes, and learns where it
    /// came from — so "Remove Download" can free its space and the Drive can give it back.
    private func link(_ id: UUID, to source: GoogleDrive.Source) {
        mutate(id) { book in
            guard book.drive == nil, book.fileNames.count == source.parts.count else { return }
            var linked = source
            linked.finished = true
            book.drive = linked
        }
    }

    /// The files of a Drive book are all down: the book is available now, and what its files say about it (title,
    /// author, cover, blurb, tags) is read as an import reads it — onto what the reader has not already changed.
    func driveDownloadFinished(_ id: UUID) async {
        guard let book = books.first(where: { $0.id == id }), let source = book.drive else { return }
        // only a book whose every part is there is available
        guard fileURLs(for: book).allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return }
        inCloud.remove(id)
        missing.remove(id)
        var fresh = book
        if book.isAudio {
            let tags = await audioTags(at: fileURL(for: book))
            if let album = tags.album { fresh.title = album }
            if let artist = tags.artist { fresh.author = artist }
            if let data = tags.artwork, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: coverURL(for: book))
            }
        } else {
            // a file Readium cannot open keeps its name for a title, and says so when it is opened
            try? await readDetails(of: &fresh, at: fileURL(for: book))
        }
        mutate(id) { b in
            if b.title == source.guessedTitle, !fresh.title.isEmpty { b.title = fresh.title }
            if b.author.isEmpty { b.author = fresh.author }
            if b.bookDescription == nil { b.bookDescription = fresh.bookDescription }
            if b.year == nil { b.year = fresh.year }
            if b.isbn == nil { b.isbn = fresh.isbn }
            if b.series == nil { b.series = fresh.series; b.seriesIndex = fresh.seriesIndex }
            b.drive?.finished = true
        }
        coverChanged()
    }

    /// Album, artist and artwork from an audio file's tags.
    private func audioTags(at url: URL) async -> (album: String?, artist: String?, artwork: Data?) {
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        func item(_ key: AVMetadataKey) -> AVMetadataItem? { metadata.first { $0.commonKey == key } }
        let album = item(.commonKeyAlbumName)?.stringValue
        return (album?.isEmpty == false ? album : nil, item(.commonKeyArtist)?.stringValue, item(.commonKeyArtwork)?.dataValue)
    }

    /// Give back the space a Drive book takes: its files go, the book stays in the library (with its place) and
    /// can be downloaded again.
    func removeDownload(_ id: UUID) {
        guard let book = books.first(where: { $0.id == id }), book.drive != nil else { return }
        DriveDownloads.shared.cancel(id)
        for url in fileURLs(for: book) { try? fm.removeItem(at: url) }
        inCloud.insert(id)
    }

    // MARK: - Shelves

    private func saveShelves() { UserDefaults.standard.set(shelves, forKey: "shelves") }

    /// Make a shelf; returns its name as stored, or the existing one when the
    /// name is taken (case-insensitively). Blank names are refused.
    @discardableResult
    func addShelf(_ raw: String) -> String? {
        // "~" marks the built-in filters ("All", "Up next") in the library's chip row
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "~" })
        let clean = String(name).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= 40 else { return nil }
        if let existing = shelves.first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        shelves.append(clean)
        saveShelves()
        return clean
    }

    func renameShelf(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespaces)
        guard let i = shelves.firstIndex(of: old), !new.isEmpty, new.count <= 40, !new.hasPrefix("~"),
              !shelves.contains(where: { $0 != old && $0.caseInsensitiveCompare(new) == .orderedSame })
        else { return }
        shelves[i] = new
        // keep the library on the shelf it was showing
        if UserDefaults.standard.string(forKey: "libraryShelf") == old {
            UserDefaults.standard.set(new, forKey: "libraryShelf")
        }
        for j in books.indices {
            books[j].collections = books[j].collections.map { $0 == old ? new : $0 }
        }
        saveShelves()
        save()
    }

    func deleteShelf(_ name: String) {
        shelves.removeAll { $0 == name }
        for j in books.indices { books[j].collections.removeAll { $0 == name } }
        saveShelves()
        save()
    }

    /// Put books on a shelf, or take them off it.
    func setShelf(_ name: String, on ids: [UUID], member: Bool) {
        let wanted = Set(ids)
        for j in books.indices where wanted.contains(books[j].id) {
            let has = books[j].collections.contains(name)
            if member, !has { books[j].collections.append(name) }
            if !member, has { books[j].collections.removeAll { $0 == name } }
        }
        save()
    }

    enum ShelfState { case none, some, all }

    func state(of name: String, among ids: [UUID]) -> ShelfState {
        let wanted = Set(ids)
        let mine = books.filter { wanted.contains($0.id) }
        let on = mine.filter { $0.collections.contains(name) }.count
        if on == 0 { return .none }
        return on == mine.count ? .all : .some
    }

    /// A cover file changed on disk — views read covers by path, so nudge them to look again.
    /// A cover was replaced — the thumbnails are stale (rare enough that
    /// dropping them all is simpler than tracking which size keys exist).
    func coverChanged() {
        coverThumbs.removeAllObjects()
        objectWillChange.send()
    }

    /// Finished: it leaves the Continue card and BookMaster shelves it as read.
    /// The position is left alone, so reopening still lands where they stopped.
    func markFinished(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].progression = 1
        save()
        let book = books[i]
        Task {
            await BookMaster.shared.syncProgress(
                bookKey: book.id.uuidString, ref: book.bookMasterRef, percent: 1,
                isAudio: book.isAudio, force: true,
                pinned: { [weak self] pin in self?.updateBookMaster(id) { $0.bookmasterId = pin } })
        }
    }

    /// A rating from the book's sheet: kept on the book, and sent to BookMaster with the place the reader is
    /// at (never a place behind BookMaster's own).
    func rate(_ id: UUID, stars: Int) {
        guard (1...5).contains(stars), let i = books.firstIndex(where: { $0.id == id }) else { return }
        let place = max(books[i].progression ?? 0, (books[i].bmRemotePercent ?? 0) / 100)
        guard place > 0 else { return }   // BookMaster takes a rating with a place; none yet, nothing to send
        books[i].bmRating = stars
        save()
        let book = books[i]
        Task {
            await BookMaster.shared.syncProgress(
                bookKey: book.id.uuidString, ref: book.bookMasterRef, percent: place,
                isAudio: book.isAudio, rating: stars, force: true,
                pinned: { [weak self] pin in self?.updateBookMaster(id) { $0.bookmasterId = pin } })
        }
    }

    /// Back to the start — for a re-read, or one abandoned part way.
    func restart(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].progression = 0
        books[i].locatorJSON = nil
        books[i].audioPosition = nil
        books[i].lastOpenedAt = nil
        ResumeOffer.decline(&books[i])   // starting over on purpose is not a question to ask again on the next open
        save()
    }

    /// Forget every BookMaster tie — after unlinking, or on a restored library.
    func clearBookMasterFields() {
        for i in books.indices {
            books[i].bookmasterId = nil
            books[i].bmStatus = nil
            books[i].bmRating = nil
            books[i].bmRemotePercent = nil
            books[i].bmUpNext = nil
        }
        save()
    }

    func delete(_ book: Book) {
        DriveDownloads.shared.cancel(book.id)
        inCloud.remove(book.id)
        missing.remove(book.id)
        for url in fileURLs(for: book) { try? fm.removeItem(at: url) }
        try? fm.removeItem(at: coverURL(for: book))
        // a restored backup can resurrect the id with different art
        coverThumbs.removeAllObjects()
        books.removeAll { $0.id == book.id }
        save()
    }

    /// Inserts a book brought back by backup restore (files already copied).
    func addRestored(_ book: Book) {
        for name in book.collections where !shelves.contains(name) { shelves.append(name) }
        saveShelves()
        books.insert(book, at: 0)
        save()
        refreshMissing()   // a Drive book restored without its files is waiting to be downloaded
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent, added, title, author, series
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Recently Opened"
            case .added: return "Recently Added"
            case .title: return "Title"
            case .author: return "Author"
            case .series: return "Series"
            }
        }
    }

    /// Filtered + sorted view of the catalogue for the library screen.
    func sortedBooks(order: SortOrder, query: String) -> [Book] {
        var list = books
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // every word must match the title or the author, ignoring case and accents
            let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
            list = list.filter { b in
                tokens.allSatisfy { b.title.localizedStandardContains($0) || b.author.localizedStandardContains($0) }
            }
        }
        switch order {
        case .recent:
            return list.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .added:
            return list.sorted { $0.addedAt > $1.addedAt }
        case .title:
            let keyed = list.map { (book: $0, title: $0.sortTitle) }
            return keyed.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.book)
        case .author:
            // books with no author last, then by last name, then by title
            let keyed = list.map { (book: $0, author: $0.sortAuthor, title: $0.sortTitle) }
            return keyed.sorted { a, b in
                if a.book.author.isEmpty != b.book.author.isEmpty { return !a.book.author.isEmpty }
                let c = a.author.localizedStandardCompare(b.author)
                return c == .orderedSame ? a.title.localizedStandardCompare(b.title) == .orderedAscending : c == .orderedAscending
            }.map(\.book)
        case .series:
            // a series together, in reading order; books outside any series after them, by title
            let keyed = list.map { (book: $0, series: $0.series ?? "", title: $0.sortTitle) }
            return keyed.sorted { a, b in
                if a.series.isEmpty != b.series.isEmpty { return !a.series.isEmpty }
                if a.series != b.series { return a.series.localizedStandardCompare(b.series) == .orderedAscending }
                if let x = a.book.seriesIndex, let y = b.book.seriesIndex, x != y { return x < y }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }.map(\.book)
        }
    }

    /// The book after `book` in its series, when the library has it and it is not finished.
    func nextInSeries(after book: Book) -> Book? {
        guard let series = book.series, let index = book.seriesIndex else { return nil }
        return books
            .filter { $0.series == series && ($0.seriesIndex ?? 0) > index && ($0.progression ?? 0) < 0.995 }
            .min { ($0.seriesIndex ?? 0) < ($1.seriesIndex ?? 0) }
    }

    // MARK: - Duplicates

    /// Letters and digits only, no case or accents: "The Hobbit." and "the hobbit" are one title.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Books that are the same title by the same author in the same kind (text or audio) — a copy imported
    /// twice. The one to keep comes first: the furthest along, then the most marked up.
    func duplicateGroups() -> [[Book]] {
        var groups: [String: [Book]] = [:]
        for book in books {
            let title = Self.fold(book.title)
            guard !title.isEmpty else { continue }
            groups["\(title)|\(Self.fold(book.author))|\(book.isAudio ? "a" : "b")", default: []].append(book)
        }
        return groups.values
            .filter { $0.count > 1 }
            .map { group in
                group.sorted {
                    if ($0.progression ?? 0) != ($1.progression ?? 0) { return ($0.progression ?? 0) > ($1.progression ?? 0) }
                    let a = $0.highlights.count + $0.bookmarks.count, b = $1.highlights.count + $1.bookmarks.count
                    return a != b ? a > b : $0.addedAt < $1.addedAt
                }
            }
            .sorted { $0[0].sortTitle.localizedStandardCompare($1[0].sortTitle) == .orderedAscending }
    }

    /// Fold copies of one book into `keep`: what they hold (highlights, bookmarks, shelves, the furthest place) is
    /// kept, their files are removed.
    func merge(keep: UUID, removing ids: [UUID]) {
        let others = books.filter { ids.contains($0.id) && $0.id != keep }
        guard !others.isEmpty else { return }
        mutate(keep) { b in
            for o in others {
                let marked = Set(b.highlights.map(\.locatorJSON))
                b.highlights += o.highlights.filter { !marked.contains($0.locatorJSON) }
                let bookmarked = Set(b.bookmarks.map(\.locatorJSON))
                b.bookmarks += o.bookmarks.filter { !bookmarked.contains($0.locatorJSON) }
                for name in o.collections where !b.collections.contains(name) { b.collections.append(name) }
                let saved = Set(b.words.map { $0.word.lowercased() })
                b.words += o.words.filter { !saved.contains($0.word.lowercased()) }
                if (o.progression ?? 0) > (b.progression ?? 0) {
                    b.progression = o.progression
                    b.locatorJSON = o.locatorJSON
                    b.audioPosition = o.audioPosition
                    b.lastOpenedAt = o.lastOpenedAt ?? b.lastOpenedAt
                }
                if b.bookmasterId == nil { b.bookmasterId = o.bookmasterId }
                if b.series == nil { b.series = o.series; b.seriesIndex = o.seriesIndex }
            }
        }
        for o in others { delete(o) }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(books)
            try data.write(to: catalogueURL, options: .atomic)
        } catch {
            Log.error("library", "catalogue save failed: \(error.localizedDescription)")
            return
        }
        SpotlightIndexer.shared.libraryChanged(self)
    }
}
