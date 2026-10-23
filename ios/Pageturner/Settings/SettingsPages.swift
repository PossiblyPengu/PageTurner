import SwiftUI
import UniformTypeIdentifiers

/// The pages Settings opens onto — each a topic, so the first screen is a list of them rather than one
/// long form. (`SettingsView` is the list.)

/// A row in the list: a coloured tile with a symbol, the topic, and — where it helps — where it stands.
struct SettingsRow: View {
    let title: String
    let symbol: String
    let tint: Color
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A page that is a form of sections someone else already wrote.
struct SettingsPageForm<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Library & import: what is added on its own, and what is searched and counted.
struct LibrarySettingsPage: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @State private var showFolderPicker = false
    @State private var message: String?
    @State private var confirmResetStats = false
    @State private var confirmClearFinished = false
    @State private var clearedMessage: String?
    @State private var hardcoverToken = ""
    @State private var hardcoverSaved = HardcoverClient.hasOwnToken
    @State private var hardcoverBusy = false
    @State private var hardcoverResult: String?
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true
    @AppStorage("stats-tracking") private var statsTracking = true
    @AppStorage("auto-clear-finished") private var autoClearFinished = false
    private let watcher = FolderWatcher.shared

    var body: some View {
        Form {
            autoImport
            finishedBooks
            hardcover
            searchAndStats
        }
        .navigationTitle("Library & import")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: spotlight) { _, on in
            SpotlightIndexer.shared.setEnabled(on, library: library)
        }
        .confirmationDialog(
            "Reset reading stats?", isPresented: $confirmResetStats, titleVisibility: .visible
        ) {
            Button("Reset Stats", role: .destructive) { ReadingLog.shared.clear() }
        } message: {
            Text("This clears the time, streaks and charts kept on this phone. BookMaster’s own numbers aren’t touched.")
        }
        .alert("Auto-import", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .alert("Finished books", isPresented: Binding(
            get: { clearedMessage != nil },
            set: { if !$0 { clearedMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearedMessage ?? "")
        }
        .confirmationDialog(
            "Clear finished books' files?", isPresented: $confirmClearFinished, titleVisibility: .visible
        ) {
            Button("Clear Files", role: .destructive, action: sweepFinished)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearConfirmText)
        }
    }

    /// Finished books still holding files, and the byte count they would free.
    private var clearable: (count: Int, local: Int, freed: Int64) {
        let targets = library.clearableFinished()
        return (targets.count, targets.filter { $0.book.drive == nil }.count,
                targets.reduce(Int64(0)) { $0 + $1.bytes })
    }

    private var clearConfirmText: String {
        let c = clearable
        var text = "Frees about \(GoogleDrive.sizeText(c.freed))."
        if c.local > 0 {
            text += " \(c.local == 1 ? "One book has" : "\(c.local) books have") no Google Drive copy — \(c.local == 1 ? "it is" : "they are") removed from the library with \(c.local == 1 ? "its" : "their") file."
        }
        text += " Your BookMaster shelf isn’t touched."
        return text
    }

    private func sweepFinished() {
        let result = router.clearFinishedBooks(library: library)
        var parts = ["Freed \(GoogleDrive.sizeText(result.freed))"]
        if result.kept > 0 {
            parts.append("\(result.kept) \(result.kept == 1 ? "book stays" : "books stay") in the library — \(result.kept == 1 ? "its" : "their") files are back in Google Drive")
        }
        if result.removed > 0 {
            parts.append("\(result.removed) \(result.removed == 1 ? "book was" : "books were") removed from the library")
        }
        clearedMessage = parts.joined(separator: "; ") + "."
    }

    private var finishedBooks: some View {
        let c = clearable
        return Section {
            Toggle("Clear files when a book is finished", isOn: $autoClearFinished)
            Button("Clear Finished Books’ Files…", role: .destructive) { confirmClearFinished = true }
                .disabled(c.count == 0)
        } header: {
            Text("Finished books")
        } footer: {
            Text(c.count == 0
                 ? "Free the space of books you have finished: a Google Drive copy goes back to the Drive (the book stays and can come down again), a book whose file is its only copy leaves the library with it."
                 : "Finished books hold \(GoogleDrive.sizeText(c.freed)) across \(c.count) \(c.count == 1 ? "book" : "books"). A Google Drive copy goes back to the Drive; a book whose file is its only copy leaves the library with it.")
        }
    }

    private var autoImport: some View {
        Section {
            if watcher.isWatching {
                LabeledContent("Watching", value: watcher.folderName ?? "")
                Button("Stop Watching", role: .destructive) { watcher.stop() }
            } else {
                Button { showFolderPicker = true } label: {
                    Label("Watch a Folder…", systemImage: "folder.badge.plus")
                }
            }
        } header: {
            Text("Auto-import")
        } footer: {
            Text("New EPUB, PDF, CBZ and audio files that appear in the folder are added to your library whenever Pageturner opens.")
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): Task { await watcher.watch(url, library: library) }
            case let .failure(error): message = error.localizedDescription
            }
        }
    }

    private var hardcover: some View {
        Section {
            SecureField("API token", text: $hardcoverToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !hardcoverToken.isEmpty {
                Button("Save and Test") { saveHardcover() }
                    .disabled(hardcoverBusy)
            }
            if hardcoverSaved {
                Button("Remove My Token", role: .destructive) {
                    HardcoverVault.remove()
                    hardcoverToken = ""
                    hardcoverSaved = false
                    hardcoverResult = nil
                }
            }
            if let hardcoverResult { Text(hardcoverResult).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Hardcover")
        } footer: {
            Text("Hardcover’s catalogue — modern books, series and covers — is part of Find Details. A token is built into the app; if you would rather use your own, get a free one at hardcover.app/account/api and paste it here. It stays in this iPhone’s Keychain and is sent only to Hardcover.")
        }
    }

    private func saveHardcover() {
        hardcoverBusy = true
        hardcoverResult = "Testing…"
        HardcoverVault.write(hardcoverToken)
        Task {
            let problem = await HardcoverClient.test()
            hardcoverBusy = false
            if let problem {
                HardcoverVault.remove()
                hardcoverSaved = false
                hardcoverResult = problem
            } else {
                hardcoverSaved = true
                hardcoverToken = ""
                hardcoverResult = "Connected. Hardcover is on."
            }
        }
    }

    private var searchAndStats: some View {
        Section {
            Toggle("Show books in Spotlight", isOn: $spotlight)
            Toggle("Track reading stats on this iPhone", isOn: $statsTracking)
            Button("Reset Reading Stats…", role: .destructive) { confirmResetStats = true }
        } header: {
            Text("Search & stats")
        } footer: {
            Text("Spotlight lists your titles, authors and covers using iOS’s own on-device index. Reading stats — sittings, streaks and the pace “time left” guesses from — are kept on this phone; switching tracking off keeps what is there and stops new ones, and resetting clears them either way. BookMaster’s own numbers aren’t touched.")
        }
    }
}

/// Settings → Backup: scheduled backups, and a backup made or restored by hand.
struct BackupSettingsPage: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var shareItem: ShareItem?
    @State private var message: String?
    @State private var showBackupImporter = false
    @State private var showDriveBackups = false
    @State private var driveRestore: GoogleDrive.File?
    @State private var backupBusy = false

    var body: some View {
        Form {
            AutoBackupSection()
            byHand
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showDriveBackups) { DriveBackupsView { driveRestore = $0 } }
        .confirmationDialog(
            "Restore from Google Drive?", isPresented: Binding(get: { driveRestore != nil }, set: { if !$0 { driveRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore") { if let file = driveRestore { restoreFromDrive(file) } }
        } message: {
            Text("Books in “\(driveRestore?.name ?? "")” that are not already here are added. Nothing is removed.")
        }
        .alert("Backup", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var byHand: some View {
        Section("By hand") {
            Button { exportBackup() } label: {
                Label {
                    HStack {
                        Text("Export Library Backup")
                        if backupBusy { Spacer(); ProgressView() }
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(backupBusy)
            Button { showBackupImporter = true } label: {
                Label("Restore Backup…", systemImage: "square.and.arrow.down")
            }
            .disabled(backupBusy)
            if GoogleAuth.shared.signedIn {
                Button { showDriveBackups = true } label: {
                    Label("Restore from Google Drive…", systemImage: "icloud.and.arrow.down")
                }
                .disabled(backupBusy)
            }
        }
        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case let .success(url): restoreBackup(url)
            case let .failure(error): message = error.localizedDescription
            }
        }
    }

    private func exportBackup() {
        message = nil
        backupBusy = true
        Task {
            defer { backupBusy = false }
            do {
                let url = try await BackupStore(library: library).exportBackup()
                shareItem = ShareItem(url: url)
            } catch {
                message = error.localizedDescription
                Log.error("backup", "export failed: \(error.localizedDescription)")
            }
        }
    }

    /// A backup from the Drive: downloaded, then restored the way a file from Files is.
    private func restoreFromDrive(_ file: GoogleDrive.File) {
        message = nil
        backupBusy = true
        Task {
            defer { backupBusy = false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drive-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let url = try await DriveClient.shared.download(file, into: directory)
                let r = try await BackupStore(library: library).importBackup(url)
                message = "Restored \(r.restored) book\(r.restored == 1 ? "" : "s")"
                    + (r.skipped > 0 ? " · skipped \(r.skipped)" : "")
            } catch {
                message = (error as? DriveError)?.message ?? error.localizedDescription
                Log.error("backup", "restore from Drive failed: \(error.localizedDescription)")
            }
        }
    }

    private func restoreBackup(_ url: URL) {
        message = nil
        backupBusy = true
        Task {
            defer { backupBusy = false }
            do {
                let r = try await BackupStore(library: library).importBackup(url)
                message = "Restored \(r.restored) book\(r.restored == 1 ? "" : "s")"
                    + (r.skipped > 0 ? " · skipped \(r.skipped)" : "")
            } catch {
                message = error.localizedDescription
                Log.error("backup", "restore failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Settings → Diagnostics: the log, and the one file that carries it.
struct DiagnosticsSettingsPage: View {
    @State private var shareItem: ShareItem?

    var body: some View {
        Form {
            Section {
                NavigationLink("View Log") { LogView() }
                Button { shareItem = ShareItem(url: Log.shareURL()) } label: {
                    Label("Share Diagnostics…", systemImage: "doc.text.magnifyingglass")
                }
                if Log.lastRunEndedUncleanly {
                    Label("Last run didn’t shut down cleanly — its crash log is in the diagnostics.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Diagnostics is one file: this run’s log, the previous one, and any crash record. The same files are in Files ▸ On My iPhone ▸ Pageturner ▸ Logs.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }
}
