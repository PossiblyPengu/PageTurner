import Foundation
import Observation

/// Watches one folder from Files (iCloud Drive, a Dropbox folder…) and imports
/// whatever new books land in it, so dropping a file there is the whole job.
///
/// The folder is kept as a security-scoped bookmark; each scan opens it,
/// imports files it hasn't seen (by path, size and modification date), and
/// closes it. A file still being written or synced is left for a later scan,
/// and an audiobook folder waits until nothing in it has changed for a while,
/// so a book whose tracks arrive over a minute isn't split in two.
@Observable
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()

    private(set) var folderName: String?
    private(set) var scanning = false

    private let bookmarkKey = "watchedFolderBookmark"
    private let seenKey = "watchedFolderSeen"
    private let seenMax = 5000
    /// The last scan — a foreground storm isn't a reason to walk the folder every time.
    private var lastScan: Date?
    /// A file touched this recently may still be arriving.
    private let fileSettle: TimeInterval = 10
    /// An audio folder has to be quiet this long before its tracks are imported.
    private let folderSettle: TimeInterval = 90
    private let supported = Set(["epub", "pdf", "cbz"]).union(Book.audioExtensions)

    private init() {
        folderName = resolve()?.lastPathComponent
    }

    var isWatching: Bool { folderName != nil }

    private struct Candidate {
        var url: URL
        var key: String
        var modified: Date
    }

    /// Start watching a folder the reader picked. Everything already in it
    /// counts as new — they chose it to have it imported.
    func watch(_ url: URL, library: LibraryStore) async {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            library.lastError = "That folder can’t be watched."
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
        folderName = url.lastPathComponent
        lastScan = nil   // a folder just chosen is scanned whatever the clock says
        await scan(library: library)
    }

    func stop() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
        folderName = nil
    }

    /// Import anything new in the folder. Safe to call often — and cheap to call again inside
    /// the same minute, when nothing could have settled since.
    func scan(library: LibraryStore) async {
        guard !scanning, let folder = resolve() else { return }
        guard lastScan.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastScan = Date()
        scanning = true
        defer { scanning = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        var seen = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let known = Set(seen)
        let supported = self.supported
        // the walk touches every file's metadata — keep it off the main actor
        let found = await Task.detached(priority: .utility) {
            Self.enumerate(folder, supported: supported)
        }.value

        let now = Date()
        let audioExts = Book.audioExtensions
        // a disc folder settles with its siblings: "Book/CD 2" still arriving
        // holds "Book/CD 1" back, or the halves import as two books
        func settleKey(_ url: URL) -> String {
            let dir = url.deletingLastPathComponent()
            return AudioGrouping.isDisc(dir.lastPathComponent)
                ? dir.deletingLastPathComponent().path : dir.path
        }
        let quietDirs = Set(
            Dictionary(grouping: found.filter { audioExts.contains($0.url.pathExtension.lowercased()) },
                       by: { settleKey($0.url) })
                .filter { $0.value.allSatisfy { now.timeIntervalSince($0.modified) >= folderSettle } }
                .keys)

        var ready: [Candidate] = []
        for item in found where !known.contains(item.key) {
            if now.timeIntervalSince(item.modified) < fileSettle { continue }
            if audioExts.contains(item.url.pathExtension.lowercased()),
               !quietDirs.contains(settleKey(item.url)) { continue }
            ready.append(item)
        }
        guard !ready.isEmpty else { return }

        await library.importFiles(ready.map { $0.url })
        // marked seen even when an import failed, so one bad file isn't retried forever
        seen.append(contentsOf: ready.map { $0.key })
        UserDefaults.standard.set(Array(seen.suffix(seenMax)), forKey: seenKey)
    }

    /// Every supported file under `folder`. iCloud files that haven't been
    /// downloaded show up as hidden `.name.icloud` placeholders — ask for
    /// those and pick the real file up on a later scan.
    nonisolated private static func enumerate(_ folder: URL, supported: Set<String>) -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        var out: [Candidate] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                continue
            }
            guard supported.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let key = "\(url.path)|\(values.fileSize ?? 0)|\(Int(modified.timeIntervalSince1970))"
            out.append(Candidate(url: url, key: key, modified: modified))
        }
        return out
    }

    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }
}
