import SwiftUI
import UniformTypeIdentifiers

/// Scheduled backups: a folder to put them in, how often, and how many to keep.
struct AutoBackupSection: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("backup-auto") private var enabled = false
    @AppStorage("backup-auto-interval") private var intervalRaw = AutoBackupPlan.Interval.weekly.rawValue
    @AppStorage("backup-auto-keep") private var keep = 3
    @AppStorage("backup-auto-dest") private var destination = "folder"
    @State private var showPicker = false
    @State private var libraryBytes: Int64?
    @State private var error: String?
    private let backup = AutoBackup.shared

    var body: some View {
        Section {
            Toggle("Back up automatically", isOn: $enabled)
            if enabled {
                Picker("Back up to", selection: $destination) {
                    Text("A folder in Files").tag("folder")
                    Text("Google Drive").tag("drive")
                }
                if destination == "drive" { driveRow } else { folderRow }
                Picker("How often", selection: $intervalRaw) {
                    ForEach(AutoBackupPlan.Interval.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Stepper("Keep the last \(keep)", value: $keep, in: 1 ... 10)
                Button {
                    Task { await backup.run(library: library) }
                } label: {
                    HStack {
                        Label("Back Up Now", systemImage: "arrow.triangle.2.circlepath")
                        if backup.running { Spacer(); ProgressView() }
                    }
                }
                .disabled(!backup.isReady || backup.running)
                if let status = backup.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Automatic backup")
        } footer: {
            Text(footer)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): error = backup.setFolder(url)
            case let .failure(failure): error = failure.localizedDescription
            }
            backup.scheduleBackground()
        }
        .onChange(of: enabled) { _, _ in backup.scheduleBackground() }
        .onChange(of: destination) { _, _ in backup.scheduleBackground() }
        .onChange(of: intervalRaw) { _, _ in backup.scheduleBackground() }
        .task { libraryBytes = await AutoBackup.libraryBytes(library) }
    }

    @ViewBuilder
    private var driveRow: some View {
        if GoogleAuth.shared.signedIn {
            LabeledContent("Google Drive", value: GoogleAuth.shared.account ?? "Signed in")
            LabeledContent("Folder", value: GoogleDrive.backupFolderName)
        } else {
            NavigationLink(value: SettingsDestination.drive) {
                Label("Sign in to Google Drive first", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        if let name = backup.folderName {
            LabeledContent("Folder", value: name)
            Button("Stop Using This Folder", role: .destructive) { backup.clearFolder() }
        } else {
            Button { showPicker = true } label: {
                Label("Choose a Folder…", systemImage: "folder.badge.plus")
            }
        }
    }

    private var footer: String {
        var text = "A backup holds every book file"
        if let libraryBytes, libraryBytes > 0 {
            text += ", so each copy is about \(AutoBackup.sizeText(libraryBytes))"
        }
        text += ". Pageturner makes one when you open it and a backup is due, and overnight while charging when iOS allows — "
            + "iOS decides when, so opening the app is the reliable one. A folder in iCloud Drive counts against your iCloud storage; "
            + "a backup in Google Drive counts against its storage and is sent over Wi-Fi or cellular."
        return text
    }
}
