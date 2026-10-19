import SwiftUI

/// Settings → Google Drive: the sign-in, a folder to watch for new books, and the way into the browser. (Backing up to
/// Drive is chosen under Backup, next to the other places a backup can go.)
struct GoogleDriveSettingsPage: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showBrowser = false
    @State private var showFolderPicker = false
    @State private var confirmSignOut = false
    private let auth = GoogleAuth.shared
    private let sync = DriveSync.shared

    var body: some View {
        Form {
            if auth.signedIn {
                account
                watching
                backupNote
            } else {
                signIn
            }
            setup
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

    private var clientID: Binding<String> {
        Binding(get: { auth.clientID }, set: { auth.clientID = $0 })
    }

    private var signIn: some View {
        Section {
            TextField("Client ID", text: clientID, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
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
            if auth.clientID.isEmpty {
                Text("Google lets an app in only with a sign-in ID of its own, so you make one, once, for your own account — the steps are below. It is a public identifier, not a password.")
            } else if !auth.isConfigured {
                Text("That does not look like a client ID: it ends in .apps.googleusercontent.com.")
            } else {
                Text("Pageturner reads the files you pick, and writes only a “\(GoogleDrive.backupFolderName)” folder of its own.")
            }
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
            Text("Browse to pick books to add. The same sign-in serves the watched folder and Drive backups.")
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
            Text("Auto-import")
        } footer: {
            Text("New EPUB, PDF, CBZ, text and audio files that land in the folder — or in a folder inside it — are added to your library when Pageturner opens, at most every ten minutes.")
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

    // MARK: Setup

    private var setup: some View {
        Section {
            DisclosureGroup("How to get a client ID") {
                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Open console.cloud.google.com and create a project (any name).")
                    step("2", "APIs & Services → Library → search “Google Drive API” → Enable.")
                    step("3", "APIs & Services → OAuth consent screen: choose External, give it a name and your email, and add your own Google account under Test users. To stop the sign-in expiring after a week, press Publish App — Google then calls the app unverified, which is fine for your own use.")
                    step("4", "Credentials → Create Credentials → OAuth client ID → Application type iOS, with the bundle ID \(Bundle.main.bundleIdentifier ?? "io.github.possiblypengu.pageturner").")
                    step("5", "Copy the Client ID it shows (it ends in .apps.googleusercontent.com), paste it above, and sign in.")
                }
                .font(.footnote)
                .padding(.vertical, 4)
            }
        } footer: {
            Text("If Google says “access blocked” or the Drive API “has not been used”, step 2 or the Test users list is the usual cause.")
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(text)
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
