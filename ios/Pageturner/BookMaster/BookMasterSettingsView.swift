import SwiftUI

/// Settings → BookMaster: the account this iPhone is linked to (or the way to link one), and what Pageturner
/// sends to it. Notifications, chat and the web apps have their own pages.
struct BookMasterAccountPage: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("bm-share-place") private var sharePlace = true
    @AppStorage("bm-covers") private var sendCovers = true
    @AppStorage("bm-resume-ask") private var resumeAsk = true
    @AppStorage("bm-quotes-auto") private var quotesAuto = false
    @State private var working = false
    @State private var error: String?
    @State private var showLink = false
    @State private var confirmUnlink = false
    private let bookMaster = BookMaster.shared
    private let notifier = Notifier.shared

    var body: some View {
        Form {
            if let user = bookMaster.user {
                accountSection(user)
                sendingSection
                readingSection
            } else {
                linkSection
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("BookMaster")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLink) {
            BookMasterLinkSheet(
                onCode: { code in
                    showLink = false
                    Task { await finishLink(code) }
                },
                onCancel: { showLink = false })
        }
    }

    // MARK: Linked

    private func accountSection(_ user: BMUser) -> some View {
        Section("Account") {
            Label(user.displayName ?? user.username, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Button("Unlink BookMaster", role: .destructive) { confirmUnlink = true }
                .alert("Unlink BookMaster?", isPresented: $confirmUnlink) {
                    Button("Unlink", role: .destructive) {
                        bookMaster.unlink()
                        library.clearBookMasterFields()
                        notifier.reset()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The link is forgotten and queued pushes with it. Nothing on BookMaster is deleted.")
                }
        }
    }

    /// What goes up to BookMaster as you read.
    private var sendingSection: some View {
        Section {
            Toggle("Send progress and sessions", isOn: Binding(
                get: { bookMaster.syncEnabled },
                set: { bookMaster.syncEnabled = $0 }
            ))
            Text(bookMaster.syncEnabled
                ? "Your reading progress and finished sessions go to BookMaster as you read and listen."
                : "Paused. Nothing is sent while you read; comments, suggestions and quotes still work.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Tell the other reader where I am", isOn: $sharePlace)
            Toggle("Send my covers", isOn: $sendCovers)
            Toggle("Send new highlights as quotes", isOn: $quotesAuto)
            if quotesAuto {
                Text("Each passage you highlight is also saved to BookMaster as a quote, once. Quotes are visible to the other reader.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What Pageturner sends")
        }
    }

    private var readingSection: some View {
        Section("Opening books") {
            Toggle("Ask to jump to BookMaster’s place", isOn: $resumeAsk)
        }
    }

    // MARK: Not linked

    private var linkSection: some View {
        Section {
            Text("Link your BookMaster account to log reading sessions, keep progress in sync and see what the other reader is on. Nothing leaves this device until you link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                showLink = true
            } label: {
                if working { ProgressView() } else { Text("Link BookMaster") }
            }
            .disabled(working)
        } header: {
            Text("Account")
        }
    }

    /// The sheet gave back a code: spend it, then let the app know who it is now.
    private func finishLink(_ code: String) async {
        working = true
        error = nil
        defer { working = false }
        if let message = await BookMasterLinker.shared.finish(code: code) {
            error = "Couldn’t link BookMaster: \(message)"
        } else {
            await bookMaster.pullShelf(into: library)
            await bookMaster.beat()
        }
    }
}

/// Settings → Notifications: instant ones through ntfy, and the ones Pageturner posts itself.
struct NotificationsSettingsPage: View {
    @AppStorage("bm-badge") private var showBadge = true
    private let notifier = Notifier.shared

    var body: some View {
        Form {
            BMNtfySection()
            localSection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifier.refreshAuthorization() }
        // coming back from iOS Settings: the permission may have changed there
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
    }

    /// Notifications Pageturner posts on its own, when iOS lets it look in the background. With instant
    /// notifications on they stand down, and only the badge is kept.
    private var localSection: some View {
        Section {
            Toggle("Notify me about suggestions", isOn: Binding(
                get: { notifier.enabled },
                set: { on in Task { await notifier.setEnabled(on) } }
            ))
            if notifier.blockedBySystem {
                Text("Notifications are turned off for Pageturner in iOS Settings.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Open iOS Settings") { openIOSSettings() }
            } else {
                if notifier.enabled, notifier.backgroundRefreshOff {
                    Text("Background App Refresh is off, so suggestions only appear when you open Pageturner.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings") { openIOSSettings() }
                }
                Text("A suggestion from the other reader shows up as a notification. iOS decides when Pageturner may check in the background, so it can take a while — and Background App Refresh has to be on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Badge the Together tab when suggestions wait", isOn: $showBadge)
        } header: {
            Text("From Pageturner itself")
        }
    }

    private func openIOSSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Settings → Chat & web apps: the floating chat button, and the sign-in the web apps share.
struct ChatAppsSettingsPage: View {
    @AppStorage("bm-chat-button") private var chatButton = true
    @State private var confirmWebSignOut = false

    var body: some View {
        Form {
            Section {
                Toggle("Chat button on every screen", isOn: $chatButton)
            } header: {
                Text("Chat")
            } footer: {
                Text("A round button that opens the chat from anywhere except while you are reading a book. Drag it to the other side, or up and down.")
            }
            Section {
                Button("Sign out of BookMaster, Kindred and Quest Log", role: .destructive) { confirmWebSignOut = true }
                    .alert("Sign out of the web apps?", isPresented: $confirmWebSignOut) {
                        Button("Sign Out", role: .destructive) { Task { await BMWebPages.shared.clearSignIns() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("BookMaster, Kindred and Quest Log opened inside Pageturner forget who you are, and anything they saved here. Your accounts and everything in them are untouched.")
                    }
            } header: {
                Text("Web apps")
            } footer: {
                Text("They open from the Together tab, signed in once for all three, and stay signed in until you do this.")
            }
        }
        .navigationTitle("Chat & web apps")
        .navigationBarTitleDisplayMode(.inline)
    }
}
