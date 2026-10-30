import SwiftUI

/// Where each row of the Settings list leads.
enum SettingsDestination: String, Hashable {
    // the suite
    case bookmaster, notifications, chat
    // reading and listening
    case reading, readaloud, playback, appearance
    // the library
    case library, backup, drive
    // support
    case diagnostics
}

/// The app's settings, reachable from every tab: a short list of topics, each its own page — the BookMaster
/// suite (account, notifications, chat and the web apps), reading and listening, the library, and support.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsDestination] = []
    /// Where the screen under this sheet said it was — handed back on the way out.
    @State private var prevPlace = "library"
    @State private var query = ""
    private let bookMaster = BookMaster.shared
    private let notifier = Notifier.shared
    private let watcher = FolderWatcher.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            debugHooks(list)
                .navigationDestination(for: SettingsDestination.self) { destination($0) }
        }
    }

    #if DEBUG
    @State private var debugVoices = false

    /// CI simulator run: open the voice list, or a settings page, without a tap (Debug/DebugScenario.swift).
    private func debugHooks<V: View>(_ content: V) -> some View {
        content
            .navigationDestination(isPresented: $debugVoices) {
                VoiceListView(selection: .constant(nil), rate: 1)
            }
            .task {
                guard let name = DebugScenario.settingsPush else { return }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if name == "voices" {
                    debugVoices = true
                } else if let page = SettingsDestination(rawValue: name) {
                    path = [page]
                }
            }
    }
    #else
    private func debugHooks<V: View>(_ content: V) -> some View { content }
    #endif

    // MARK: The list

    /// Every destination the list can show — what the search field matches on.
    /// Keep in step with the sections below.
    private var searchableRows: [(page: SettingsDestination, title: String, symbol: String, tint: Color)] {
        var rows: [(SettingsDestination, String, String, Color)] = [
            (.bookmaster, "BookMaster", "link", .ptAccent),
            (.reading, "Reading", "book.fill", .blue),
            (.readaloud, "Read Aloud", "speaker.wave.2.fill", .indigo),
            (.playback, "Audiobooks", "headphones", .orange),
            (.appearance, "Appearance", "circle.lefthalf.filled", .purple),
            (.library, "Library & import", "books.vertical.fill", .green),
            (.drive, "Google Drive", "icloud.and.arrow.down.fill", .blue),
            (.backup, "Backup", "externaldrive.fill", .teal),
            (.diagnostics, "Diagnostics", "stethoscope", .gray),
        ]
        if bookMaster.isLinked {
            rows.insert(contentsOf: [
                (.notifications, "Notifications", "bell.badge.fill", .red),
                (.chat, "Chat & web apps", "bubble.left.and.bubble.right.fill", .blue),
            ], at: 1)
        }
        return rows
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var list: some View {
        Form {
            if searching {
                // a flat list while searching — sections would only crowd it
                Section {
                    ForEach(Array(searchableRows.filter {
                        $0.title.localizedCaseInsensitiveContains(query)
                    }.enumerated()), id: \.offset) { _, match in
                        row(match.page, match.title, match.symbol, match.tint)
                    }
                }
            } else {
            suite
            Section("Reading & listening") {
                row(.reading, "Reading", "book.fill", .blue)
                row(.readaloud, "Read Aloud", "speaker.wave.2.fill", .indigo)
                row(.playback, "Audiobooks", "headphones", .orange)
                row(.appearance, "Appearance", "circle.lefthalf.filled", .purple)
            }
            Section("Your library") {
                row(.library, "Library & import", "books.vertical.fill", .green,
                    detail: watcher.isWatching ? "Watching a folder" : nil)
                row(.drive, "Google Drive", "icloud.and.arrow.down.fill", .blue,
                    detail: driveDetail)
                row(.backup, "Backup", "externaldrive.fill", .teal)
            }
            Section {
                row(.diagnostics, "Diagnostics", "stethoscope", .gray)
                LabeledContent("Version", value: version)
            } header: {
                Text("Support")
            } footer: {
                Text("Reading is built on the Readium toolkit.")
            }
            }
        }
        .navigationTitle("Settings")
        .searchable(text: $query, prompt: "Search settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { prevPlace = BookMaster.shared.place; BookMaster.shared.place = "settings" }
        .onDisappear { BookMaster.shared.place = prevPlace }
    }

    /// BookMaster and everything that rides on it. Unlinked, it is the one row that leads to linking.
    @ViewBuilder
    private var suite: some View {
        Section {
            row(.bookmaster, "BookMaster", "link", .ptAccent, detail: accountDetail)
            if bookMaster.isLinked {
                row(.notifications, "Notifications", "bell.badge.fill", .red, detail: notificationsDetail)
                row(.chat, "Chat & web apps", "bubble.left.and.bubble.right.fill", .blue)
            }
        } header: {
            Text("BookMaster suite")
        } footer: {
            if !bookMaster.isLinked {
                Text("Link BookMaster to chat with the other reader, open Kindred and Quest Log inside Pageturner, and get instant notifications.")
            }
        }
    }

    private var accountDetail: String {
        guard let user = bookMaster.user else { return "Not linked" }
        return user.displayName ?? user.username
    }

    private var driveDetail: String? {
        let auth = GoogleAuth.shared
        if auth.signedIn { return DriveSync.shared.isWatching ? "Watching a folder" : "Signed in" }
        return nil
    }

    private var notificationsDetail: String {
        notifier.enabled ? "On" : "Off"
    }

    private func row(
        _ page: SettingsDestination, _ title: String, _ symbol: String, _ tint: Color, detail: String? = nil
    ) -> some View {
        NavigationLink(value: page) {
            SettingsRow(title: title, symbol: symbol, tint: tint, detail: detail)
        }
    }

    // MARK: The pages

    @ViewBuilder
    private func destination(_ page: SettingsDestination) -> some View {
        switch page {
        case .bookmaster: BookMasterAccountPage()
        case .notifications: NotificationsSettingsPage()
        case .chat: ChatAppsSettingsPage()
        case .reading: SettingsPageForm("Reading") { ReadingSection() }
        case .readaloud: SettingsPageForm("Read Aloud") { ReadAloudSection() }
        case .playback: SettingsPageForm("Audiobooks") { PlaybackSection() }
        case .appearance: SettingsPageForm("Appearance") { AppearanceSection() }
        case .library: LibrarySettingsPage()
        case .backup: BackupSettingsPage()
        case .drive: GoogleDriveSettingsPage()
        case .diagnostics: DiagnosticsSettingsPage()
        }
    }
}
