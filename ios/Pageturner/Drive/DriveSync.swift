import Foundation
import Observation

/// Downloading Drive files straight into the library — what cannot be a library entry before it is opened (a zip, a
/// text file) is brought in this way. Each file is downloaded into a fresh temporary folder (mirroring the Drive's
/// folders) and handed to the library's own importer. Books are not: they are added as entries and downloaded one at a
/// time, when asked for (`DriveBooks`, `DriveDownloads`).
@MainActor
enum DriveTransfer {
    /// A file and the Drive folder path it sits in ("Audiobooks/Dune", or "" for none).
    typealias Item = (file: GoogleDrive.File, folder: String)

    /// Download `items` and import them. Returns the files that came down, and what could not.
    static func bring(
        _ items: [Item], into library: LibraryStore, progress: @escaping (String) -> Void = { _ in }
    ) async -> (came: [GoogleDrive.File], failures: [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        var came: [GoogleDrive.File] = []
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress("Downloading \(index + 1) of \(items.count): \(item.file.name)")
            var directory = root
            for part in item.folder.split(separator: "/") {
                directory.appendPathComponent(String(part).replacingOccurrences(of: ":", with: "-"))
            }
            do {
                urls.append(try await DriveClient.shared.download(item.file, into: directory))
                came.append(item.file)
            } catch is CancellationError {
                break
            } catch {
                failures.append((error as? DriveError)?.message ?? "\(item.file.name): \(error.localizedDescription)")
            }
        }
        if !urls.isEmpty {
            progress("Adding to your library…")
            await library.importFiles(urls)
        }
        return (came, failures)
    }
}

/// Watches one Google Drive folder and adds whatever new books land in it to the library, so dropping a file there is
/// the whole job — what `FolderWatcher` does for a folder in Files, without needing the Drive app to have synced it.
/// Nothing is downloaded by a look: a new book is an entry in the library, downloaded when the reader asks.
///
/// The folder is remembered by its Drive id. A look lists its books (subfolders too) and compares each file's id and
/// checksum with what was added before. It looks when the app opens, and no more often than every ten minutes unless
/// asked. A file touched in the last half minute may still be uploading, so it waits for the next look.
@Observable
@MainActor
final class DriveSync {
    static let shared = DriveSync()

    private(set) var folderName: String?
    private(set) var scanning = false
    /// What happened last, as a sentence.
    private(set) var status: String?

    private let idKey = "drive-sync-id"
    private let nameKey = "drive-sync-name"
    private let seenKey = "drive-sync-seen"
    private let lastKey = "drive-sync-last"
    private let statusKey = "drive-sync-status"
    private let seenMax = 5000
    private let gap: TimeInterval = 10 * 60
    private var defaults: UserDefaults { .standard }

    private init() {
        if defaults.string(forKey: idKey) != nil { folderName = defaults.string(forKey: nameKey) }
        status = defaults.string(forKey: statusKey)
    }

    var isWatching: Bool { defaults.string(forKey: idKey) != nil }

    /// Start watching a folder the reader picked. Everything already in it counts as new: they chose it to have it
    /// imported.
    func watch(_ folder: GoogleDrive.File, library: LibraryStore) async {
        let target = folder.resolved
        defaults.set(target.id, forKey: idKey)
        defaults.set(folder.name, forKey: nameKey)
        defaults.removeObject(forKey: seenKey)
        defaults.set(0.0, forKey: lastKey)
        folderName = folder.name
        await scan(library: library)
    }

    func stop() {
        for key in [idKey, nameKey, seenKey, lastKey, statusKey] { defaults.removeObject(forKey: key) }
        folderName = nil
        status = nil
    }

    /// Look now and then (when the app opens), not every time.
    func scanIfDue(library: LibraryStore) async {
        guard isWatching, GoogleAuth.shared.signedIn, !LowPower.on,
              Date().timeIntervalSince1970 - defaults.double(forKey: lastKey) >= gap
        else { return }
        await scan(library: library)
    }

    /// Add anything new in the folder to the library. Nothing is downloaded: a book arrives as an entry that can be
    /// downloaded on its own (a zip or a text file cannot be an entry before it is opened, so those are left, and said so).
    func scan(library: LibraryStore) async {
        guard !scanning, let id = defaults.string(forKey: idKey) else { return }
        guard GoogleAuth.shared.signedIn else {
            report("Sign in to Google Drive to check the folder.")
            return
        }
        scanning = true
        defer { scanning = false }
        do {
            let found = try await DriveClient.shared.books(under: id)
            let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
            let fresh = Set(GoogleDrive.newFiles(found.map(\.file), seen: seen, now: Date()).map(\.id))
            defaults.set(Date().timeIntervalSince1970, forKey: lastKey)
            let wanted = found.filter { fresh.contains($0.file.id) }.map { DriveBooks.Found($0.file, folder: $0.folder) }
            guard !wanted.isEmpty else {
                report("Checked \(Date().formatted(date: .abbreviated, time: .shortened)): nothing new.")
                return
            }
            let result = DriveBooks.plan(wanted, known: library.driveFileIDs)
            let added = library.addFromDrive(result.books)
            let addedIDs = added.map(\.id)
            Task { await MetadataLookup.enrichDriveBooks(addedIDs, library: library) }
            // remembered once it is in the library — so one taken out again is not put back — except what was left alone
            let left = Set(result.direct.map(\.file.id))
            let keys = wanted.filter { !left.contains($0.file.id) }.map { GoogleDrive.syncKey($0.file) }
            defaults.set(GoogleDrive.remembering(defaults.stringArray(forKey: seenKey) ?? [], adding: keys, max: seenMax), forKey: seenKey)
            let time = Date().formatted(date: .omitted, time: .shortened)
            var text = added.isEmpty
                ? "Checked \(time): nothing new."
                : "Added \(added.count) book\(added.count == 1 ? "" : "s") from Drive, \(time). Open one to download it."
            if !left.isEmpty {
                text += " \(left.count) zip or text file\(left.count == 1 ? " was" : "s were") left in Drive: add \(left.count == 1 ? "it" : "them") from Browse Google Drive."
            }
            report(text)
        } catch {
            report("Couldn’t check Google Drive: \((error as? DriveError)?.message ?? error.localizedDescription)")
            Log.error("drive", "sync failed: \(error.localizedDescription)")
        }
    }

    private func report(_ text: String) {
        status = text
        defaults.set(text, forKey: statusKey)
    }
}

/// Scheduled backups into Drive: the zip goes to "Pageturner Backups" (a folder the app made, the only place the
/// `drive.file` permission lets it write), under the day's name, and the oldest copies beyond the few kept are
/// deleted. It never touches anything else in the Drive.
@MainActor
enum DriveBackup {
    static func place(_ zip: URL, keep: Int) async throws {
        let client = DriveClient.shared
        let folder = try await client.backupFolder()
        let name = AutoBackupPlan.fileName(for: Date())
        // a second backup on the same day replaces the first — once the new one is safely up
        let sameDay = (try? await client.list(query: "\(GoogleDrive.children(of: folder.id)) and name = \(GoogleDrive.quoted(name))")) ?? []
        try await client.upload(zip, name: name, to: folder.id)
        for old in sameDay { try? await client.delete(old.id) }
        let all = (try? await client.list(query: GoogleDrive.children(of: folder.id))) ?? []
        for stale in GoogleDrive.staleBackups(all, keep: keep) { try? await client.delete(stale.id) }
    }
}
