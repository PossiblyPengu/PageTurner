import SwiftUI

/// Link (or unlink) this device's BookMaster account — sections for the settings form.
struct BookMasterSection: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("bm-share-place") private var sharePlace = true
    @AppStorage("bm-covers") private var sendCovers = true
    @AppStorage("bm-resume-ask") private var resumeAsk = true
    @AppStorage("bm-badge") private var showBadge = true
    @AppStorage("bm-quotes-auto") private var quotesAuto = false
    @State private var working = false
    @State private var error: String?
    @State private var showLink = false
    @State private var confirmUnlink = false
    @State private var confirmWebSignOut = false
    private let bookMaster = BookMaster.shared
    private let notifier = Notifier.shared

    var body: some View {
        Group {
            if let user = bookMaster.user {
                Section("BookMaster") {
                    Label(user.displayName ?? user.username, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
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
                    Toggle("Ask to jump to BookMaster’s place", isOn: $resumeAsk)
                    Toggle("Notify me about suggestions", isOn: Binding(
                        get: { notifier.enabled },
                        set: { on in Task { await notifier.setEnabled(on) } }
                    ))
                    if notifier.blockedBySystem {
                        Text("Notifications are turned off for Pageturner in iOS Settings.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else {
                        if notifier.enabled, notifier.backgroundRefreshOff {
                            Text("Background App Refresh is off, so suggestions only appear when you open Pageturner.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                        Text("A suggestion from the other reader shows up as a notification. iOS decides when Pageturner may check in the background, so it can take a while — and Background App Refresh has to be on.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Badge the BookMaster tab when suggestions wait", isOn: $showBadge)
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
            } else {
                Section("BookMaster") {
                    Text("Link your BookMaster account to log reading sessions, keep progress in sync and see what the other reader is on. Nothing leaves this device until you link.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        showLink = true
                    } label: {
                        if working { ProgressView() } else { Text("Link BookMaster") }
                    }
                    .disabled(working)
                }
            }
            if bookMaster.isLinked { BMNtfySection() }
            Section("Web apps") {
                Button("Sign out of BookMaster, Kindred and Quest Log", role: .destructive) { confirmWebSignOut = true }
                    .alert("Sign out of the web apps?", isPresented: $confirmWebSignOut) {
                        Button("Sign Out", role: .destructive) { Task { await BMWebPages.shared.clearSignIns() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("BookMaster, Kindred and Quest Log opened inside Pageturner forget who you are, and anything they saved here. Your accounts and everything in them are untouched.")
                    }
                Text("They open from the Together tab, signed in once for all three, and stay signed in until you do this.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .task { await notifier.refreshAuthorization() }
        // coming back from iOS Settings: the permission may have changed there
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
        .sheet(isPresented: $showLink) {
            BookMasterLinkSheet(
                onCode: { code in
                    showLink = false
                    Task { await finishLink(code) }
                },
                onCancel: { showLink = false })
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
