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

/// Settings → Notifications: how Pageturner tells you — a banner while it is open, the list to come back
/// to, and a notification (with Pageturner's own icon) when it is not.
struct NotificationsSettingsPage: View {
    @AppStorage("bm-banners") private var banners = true
    @AppStorage("bm-badge") private var showBadge = true
    @AppStorage("bm-stay-connected") private var stayConnected = false
    private let notifier = Notifier.shared
    private let inbox = BMInboxStore.shared

    var body: some View {
        Form {
            insideSection
            outsideSection
            Section {
                Toggle("Badge the Together tab and the app icon", isOn: $showBadge)
            } footer: {
                Text("The number of notifications you haven’t looked at.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifier.refreshAuthorization() }
        // coming back from iOS Settings: the permission may have changed there
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
        .onChange(of: stayConnected) { _, _ in BackgroundKeepAlive.shared.update(background: false) }
    }

    /// While Pageturner is open.
    private var insideSection: some View {
        Section {
            NavigationLink {
                BMInboxView()
            } label: {
                LabeledContent("Notification list", value: inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread" : "")
            }
            Toggle("Banners while Pageturner is open", isOn: $banners)
        } header: {
            Text("In Pageturner")
        } footer: {
            Text("Everything you are told is kept in the list: suggestions, chat messages, and news from Kindred and Quest Log. A banner says it as it arrives, and is left out while you are reading a book.")
        }
    }

    /// While it is closed.
    private var outsideSection: some View {
        Section {
            Toggle("Notify me when Pageturner is closed", isOn: Binding(
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
                    Text("Background App Refresh is off, so notifications only appear when you open Pageturner.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings") { openIOSSettings() }
                }
            }
            if notifier.enabled {
                Toggle("Stay connected in the background", isOn: $stayConnected)
            }
        } header: {
            Text("Outside Pageturner")
        } footer: {
            Text(stayConnected && notifier.enabled
                ? "Pageturner keeps itself running with a silent sound and looks for news every half minute, so a notification arrives within about a minute. It uses more battery, and iOS may still end the app after some hours — open Pageturner again to start it over."
                : "A notification is posted by Pageturner itself. Without staying connected, iOS decides when Pageturner may look in the background, so one can take a while — and Background App Refresh has to be on.")
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
                        Text("BookMaster, Kindred and Quest Log opened inside Pageturner forget who you are, and anything they saved here — and Quest Log’s private chat locks again. Your accounts and everything in them are untouched.")
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
