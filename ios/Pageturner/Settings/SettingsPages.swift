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
    @State private var showFolderPicker = false
    @State private var message: String?
    @State private var confirmResetStats = false
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true
    @AppStorage("stats-tracking") private var statsTracking = true
    private let watcher = FolderWatcher.shared

    var body: some View {
        Form {
            autoImport
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
    @State private var backupBusy = false

    var body: some View {
        Form {
            AutoBackupSection()
            byHand
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
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
