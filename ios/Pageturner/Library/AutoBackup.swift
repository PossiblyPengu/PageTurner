import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Asks iOS for a little longer when the app is put away in the middle of a backup.
@MainActor
private final class BackupTimeGrant {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "library backup") { [weak self] in
            // iOS calls this on the main thread, and wants the task ended before it returns
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Library backups made on a schedule, into a folder from Files (iCloud Drive, a drive…) the reader picked, or into
/// the "Pageturner Backups" folder of their Google Drive (`DriveBackup`).
///
/// The same zip "Export Library Backup" makes, named by day, with the oldest copies cleared away beyond the
/// few kept. It is made when the app opens and a backup is due, and overnight while charging when iOS allows
/// (a background processing task — iOS decides when, so opening the app is the reliable one). A backup holds
/// every book file, so it checks there is room first and the setting says how big a copy is.
/// When one is due and what it is called live in `AutoBackupPlan`.
@Observable
@MainActor
final class AutoBackup {
    static let shared = AutoBackup()
    static let taskID = "io.github.possiblypengu.pageturner.backup"

    private(set) var folderName: String?
    private(set) var running = false
    /// What happened last, as a sentence — shown under the setting.
    private(set) var status: String?

    // The same keys the settings page's @AppStorage reads.
    private let enabledKey = "backup-auto"
    private let intervalKey = "backup-auto-interval"
    private let keepKey = "backup-auto-keep"
    private let bookmarkKey = "backup-auto-folder"
    private let lastKey = "backup-auto-last"
    private let destinationKey = "backup-auto-dest"
    private let statusKey = "backup-auto-status"
    private var defaults: UserDefaults { .standard }

    private init() {
        folderName = resolve()?.lastPathComponent
        status = defaults.string(forKey: statusKey)
    }

    var enabled: Bool { defaults.bool(forKey: enabledKey) }
    var interval: AutoBackupPlan.Interval { AutoBackupPlan.Interval(rawValue: defaults.string(forKey: intervalKey) ?? "") ?? .weekly }
    var keep: Int {
        let stored = defaults.integer(forKey: keepKey)
        return stored > 0 ? stored : 3
    }
    /// Copies go to Google Drive rather than a folder in Files.
    var usesDrive: Bool { defaults.string(forKey: destinationKey) == "drive" }
    /// Switched on, and somewhere to put the copies.
    var isReady: Bool { enabled && (usesDrive ? GoogleAuth.shared.signedIn : folderName != nil) }

    // MARK: Folder

    /// Use the folder the reader picked. It is kept as a security-scoped bookmark.
    func setFolder(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return "That folder can’t be used for backups."
        }
        defaults.set(data, forKey: bookmarkKey)
        folderName = url.lastPathComponent
        return nil
    }

    func clearFolder() {
        defaults.removeObject(forKey: bookmarkKey)
        folderName = nil
        scheduleBackground()
    }

    private func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    // MARK: Running

    /// Make a backup if one is due. Safe to call often: it does nothing while one is running, with Low Power Mode
    /// on, or when the schedule says it is too soon.
    func runIfDue(library: LibraryStore) async {
        guard isReady, !LowPower.on,
              AutoBackupPlan.isDue(last: defaults.double(forKey: lastKey), now: Date(), interval: interval)
        else { return }
        await run(library: library)
    }

    /// Back up now, into the chosen folder. True when a copy was made.
    @discardableResult
    func run(library: LibraryStore) async -> Bool {
        guard !running else { return false }
        let toDrive = usesDrive
        let folder = toDrive ? nil : resolve()
        if !toDrive, folder == nil { return false }
        if toDrive, !GoogleAuth.shared.signedIn {
            report("Sign in to Google Drive (Settings → Google Drive) to back up there.")
            return false
        }
        running = true
        let grant = BackupTimeGrant()
        defer {
            running = false
            grant.end()
            scheduleBackground()
        }

        let needed = await Self.bytes(of: library.books.flatMap { library.fileURLs(for: $0) })
        guard AutoBackupPlan.hasRoom(needed: needed, free: Self.freeSpace()) else {
            report("Skipped: there isn’t room on this iPhone for a \(Self.sizeText(needed)) backup.")
            return false
        }
        do {
            let zip = try await BackupStore(library: library).exportBackup()
            defer { try? FileManager.default.removeItem(at: zip) }
            if toDrive {
                try await DriveBackup.place(zip, keep: keep)
            } else if let folder {
                try await Self.place(zip, in: folder, keep: keep)
            }
            defaults.set(Date().timeIntervalSince1970, forKey: lastKey)
            report("Backed up\(toDrive ? " to Google Drive" : "") \(Date().formatted(date: .abbreviated, time: .shortened)).")
            return true
        } catch {
            report("Backup failed: \(error.localizedDescription)")
            Log.error("backup", "scheduled backup failed: \(error.localizedDescription)")
            return false
        }
    }

    private func report(_ text: String) {
        status = text
        defaults.set(text, forKey: statusKey)
    }

    /// Copy the zip into the folder under today's name and clear away the oldest copies. Off the main actor: it
    /// can be gigabytes, and a folder in iCloud Drive is written through a file coordinator.
    nonisolated private static func place(_ zip: URL, in folder: URL, keep: Int) async throws {
        try await Task.detached(priority: .utility) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let destination = folder.appendingPathComponent(AutoBackupPlan.fileName(for: Date()))

            var failure: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                do {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: zip, to: target)
                } catch {
                    failure = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let failure { throw failure }

            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            for old in AutoBackupPlan.stale(names, keep: keep) {
                NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(old), options: .forDeleting, error: nil) { target in
                    _ = try? fm.removeItem(at: target)
                }
            }
        }.value
    }

    // MARK: Background

    /// Called as the app launches: iOS wants the handler registered before launch ends.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task { @MainActor in
                let made = await AutoBackup.shared.runInBackground()
                task.setTaskCompleted(success: made)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Line up the next overnight run — or drop it when backups are off.
    func scheduleBackground() {
        let scheduler = BGTaskScheduler.shared
        guard isReady else {
            scheduler.cancel(taskRequestWithIdentifier: Self.taskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = usesDrive
        request.earliestBeginDate = AutoBackupPlan.nextRun(last: defaults.double(forKey: lastKey), now: Date(), interval: interval)
        try? scheduler.submit(request)
    }

    /// What the system's processing task runs. The app may have been woken without a window, so this reads the
    /// library from disk itself (the copy is only read).
    private func runInBackground() async -> Bool {
        defer { scheduleBackground() }
        guard isReady, AutoBackupPlan.isDue(last: defaults.double(forKey: lastKey), now: Date(), interval: interval) else { return true }
        return await run(library: LibraryStore())
    }

    // MARK: Sizes

    /// What the library's files add up to — about what one backup weighs.
    static func libraryBytes(_ library: LibraryStore) async -> Int64 {
        await bytes(of: library.books.flatMap { library.fileURLs(for: $0) })
    }

    nonisolated private static func bytes(of urls: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) {
            urls.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }.value
    }

    nonisolated private static func freeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
