import SwiftUI

/// Settings → Google Drive: the sign-in, a folder to watch for new books, and the way into the browser. (Backing up to
/// Drive is chosen under Backup, next to the other places a backup can go.) The client ID is built in: the reader just
/// signs in.
struct GoogleDriveSettingsPage: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showBrowser = false
    @State private var showFolderPicker = false
    @State private var confirmSignOut = false
    @AppStorage(DriveDownloads.cellularKey) private var cellular = true
    private let auth = GoogleAuth.shared
    private let sync = DriveSync.shared

    var body: some View {
        Form {
            if auth.signedIn {
                account
                downloads
                watching
                backupNote
            } else {
                signIn
            }
        }
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBrowser) { DriveBrowserView(purpose: .importBooks) }
        .sheet(isPresented: $showFolderPicker) {
            DriveBrowserView(purpose: .chooseFolder) { folder in
                Task { await sync.watch(folder, library: library) }
            }
        }
        .confirmationDialog("Sign out of Google Drive?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("Backups to Drive and the watched folder stop until you sign in again. Nothing in your Drive is touched.")
        }
        .task { if auth.signedIn { await auth.loadAccount() } }
    }

    // MARK: Signed out

    private var signIn: some View {
        Section {
            Button { Task { await auth.signIn() } } label: {
                HStack {
                    Label("Sign In with Google", systemImage: "person.crop.circle.badge.checkmark")
                    if auth.busy { Spacer(); ProgressView() }
                }
            }
            .disabled(!auth.isConfigured || auth.busy)
            if let error = auth.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text("Pageturner reads the files you pick, and writes only a “\(GoogleDrive.backupFolderName)” folder of its own. Nothing is sent anywhere but your own Drive.")
        }
    }

    // MARK: Signed in

    private var account: some View {
        Section {
            LabeledContent("Signed in as", value: auth.account ?? "—")
            Button { showBrowser = true } label: {
                Label("Browse Google Drive…", systemImage: "externaldrive")
            }
            Button("Sign Out", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Account")
        } footer: {
            Text("Browse to pick books to add to your library. The same sign-in serves the watched folder and Drive backups.")
        }
    }

    private var downloads: some View {
        Section {
            Toggle("Download over mobile data", isOn: $cellular)
        } header: {
            Text("Downloads")
        } footer: {
            Text("Books from Drive are added to your library without being downloaded: open one and tap Download. Downloads go on with the app closed, and pick up again after a lost connection. Large audiobooks are best on Wi-Fi.")
        }
    }

    private var watching: some View {
        Section {
            if sync.isWatching {
                LabeledContent("Watching", value: sync.folderName ?? "")
                if let status = sync.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await sync.scan(library: library) }
                } label: {
                    HStack {
                        Label("Check Now", systemImage: "arrow.triangle.2.circlepath")
                        if sync.scanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(sync.scanning)
                Button("Stop Watching", role: .destructive) { sync.stop() }
            } else {
                Button { showFolderPicker = true } label: {
                    Label("Watch a Drive Folder…", systemImage: "folder.badge.plus")
                }
            }
        } header: {
            Text("Watch a folder")
        } footer: {
            Text("New EPUB, PDF, CBZ and audio files that land in the folder — or in a folder inside it — are added to your library when Pageturner opens, at most every ten minutes. They are not downloaded: open a book and tap Download.")
        }
    }

    private var backupNote: some View {
        Section {
            NavigationLink(value: SettingsDestination.backup) {
                Label("Back up to Google Drive", systemImage: "externaldrive.badge.icloud")
            }
        } footer: {
            Text("Choose Google Drive under Backup → Back up to. Restoring a backup from Drive is there too.")
        }
    }
}

/// The backups in Google Drive, newest first, to restore one from.
struct DriveBackupsView: View {
    let onPick: (GoogleDrive.File) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var backups: [GoogleDrive.File] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(backups) { file in
                    Button { onPick(file); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: file)).foregroundStyle(.primary)
                            Text([GoogleDrive.sizeText(file.size), file.name].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if backups.isEmpty, error == nil {
                    ContentUnavailableView("No backups in Google Drive", systemImage: "externaldrive",
                                           description: Text("Turn on Back up automatically and choose Google Drive, then Back Up Now."))
                }
            }
            .ptSoftScrollEdges()
            .navigationTitle("Restore from Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
    }

    /// "18 October 2026", from the day the file's name carries.
    private func label(for file: GoogleDrive.File) -> String {
        let stamp = file.name.dropFirst(AutoBackupPlan.filePrefix.count).prefix(10)
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: String(stamp)) else { return file.name }
        return date.formatted(date: .long, time: .omitted)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { backups = try await DriveClient.shared.backups() }
        catch { self.error = (error as? DriveError)?.message ?? error.localizedDescription }
    }
}
