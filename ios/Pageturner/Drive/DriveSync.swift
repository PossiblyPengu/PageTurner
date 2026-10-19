import Foundation
import Observation

/// Bringing Drive files into the library: the files a reader picked, a whole folder, or what is new in the folder
/// being watched. Each is downloaded into a fresh temporary folder (mirroring the Drive's folders, so an audiobook's
/// parts stay together and its disc folders still merge) and handed to the library's own importer.
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

/// Watches one Google Drive folder and imports whatever new books land in it, so dropping a file there is the whole
/// job — what `FolderWatcher` does for a folder in Files, without needing the Drive app to have synced it.
///
/// The folder is remembered by its Drive id. A look lists its books (subfolders too), compares each file's id and
/// checksum with what was brought in before, and downloads the new ones. It looks when the app opens, and no more
/// often than every ten minutes unless asked. A file touched in the last half minute may still be uploading, so
/// it waits for the next look; one that failed to download is tried again then.
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

    /// Import anything new in the folder.
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
            let fresh = GoogleDrive.newFiles(found.map(\.file), seen: seen, now: Date())
            defaults.set(Date().timeIntervalSince1970, forKey: lastKey)
            guard !fresh.isEmpty else {
                report("Checked \(Date().formatted(date: .abbreviated, time: .shortened)): nothing new.")
                return
            }
            let paths = Dictionary(found.map { ($0.file.id, $0.folder) }, uniquingKeysWith: { first, _ in first })
            let items: [DriveTransfer.Item] = fresh.map { ($0, paths[$0.id] ?? "") }
            let (came, failures) = await DriveTransfer.bring(items, into: library) { [weak self] text in self?.status = text }
            // remembered once it is in (an import that failed is not retried for ever; a download that failed is)
            let keys = came.map(GoogleDrive.syncKey)
            defaults.set(GoogleDrive.remembering(defaults.stringArray(forKey: seenKey) ?? [], adding: keys, max: seenMax), forKey: seenKey)
            if failures.isEmpty {
                report("Added \(came.count) book\(came.count == 1 ? "" : "s") from Drive, \(Date().formatted(date: .omitted, time: .shortened)).")
            } else {
                report("Added \(came.count); \(failures.count) could not come down: \(failures[0])")
                Log.error("drive", "sync: \(failures.joined(separator: " | "))")
            }
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
