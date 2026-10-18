import SwiftUI

/// Instant notifications, for the settings form.
///
/// A sideloaded app has no push entitlement, so iOS cannot deliver real push to Pageturner itself.
/// The free ntfy app can: BookMaster sends every notification from all four apps — chat,
/// suggestions, Kindred, Quest Log — to a private topic, and ntfy shows it the moment it arrives,
/// Pageturner open or not. This section makes the topic, and says what to type into ntfy.
struct BMNtfySection: View {
    @State private var status: BMNtfyStatus?
    @State private var loading = true
    @State private var working = false
    @State private var info: String?
    @State private var error: String?
    @State private var confirmOff = false
    @State private var confirmRotate = false

    var body: some View {
        Section("Instant notifications through ntfy (alternative)") {
            content
            if let info { Text(info).font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let status {
            if !status.available {
                Text("This BookMaster isn’t set up to send instant notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if status.isOn {
                onBody(status)
            } else {
                offBody
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Button("Try Again") { Task { await load() } }
        }
    }

    // MARK: Off

    private var offBody: some View {
        Group {
            Text("Pageturner is installed outside the App Store, so iOS can’t push to it. The free ntfy app can: BookMaster sends every notification — chat, suggestions, Kindred and Quest Log — to a private topic and ntfy shows it at once, even when Pageturner is closed.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                Task { await change(link: "pageturner") }
            } label: {
                if working { ProgressView() } else { Text("Turn On") }
            }
            .disabled(working)
        }
    }

    // MARK: On

    @ViewBuilder
    private func onBody(_ status: BMNtfyStatus) -> some View {
        steps(status)
        Button { Task { await test() } } label: {
            Label("Send a Test Notification", systemImage: "bell.badge")
        }
        .disabled(working)
        Toggle("Open Pageturner when tapped", isOn: Binding(
            get: { status.opensPageturner },
            set: { on in Task { await change(link: on ? "pageturner" : "web") } }))
        Text("Off: a tap opens the page on the web instead. If tapping a notification doesn’t open Pageturner, turn this off.")
            .font(.footnote).foregroundStyle(.secondary)
        Toggle("Show the words of a chat message", isOn: Binding(
            get: { status.preview },
            set: { on in Task { await change(preview: on) } }))
        Text("Off: only who wrote. Everything sent passes through \(BMNtfy.serverLabel(status.server)), and the topic is the only secret — anyone who has it can read your notifications.")
            .font(.footnote).foregroundStyle(.secondary)
        Button("Use a New Topic…", role: .destructive) { confirmRotate = true }
            .alert("Use a new topic?", isPresented: $confirmRotate) {
                Button("Use a New Topic", role: .destructive) { Task { await change(rotate: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The old one stops working. Add the new topic to ntfy afterwards.")
            }
        Button("Turn Off", role: .destructive) { confirmOff = true }
            .alert("Turn off instant notifications?", isPresented: $confirmOff) {
                Button("Turn Off", role: .destructive) { Task { await turnOff() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("BookMaster stops sending to ntfy. Pageturner goes back to checking now and then in the background.")
            }
    }

    private func steps(_ status: BMNtfyStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Install ntfy").font(.subheadline.weight(.semibold))
            Button("Open ntfy") { openNtfy() }
                .font(.subheadline)
            Text("2. In ntfy, tap + and subscribe to this topic").font(.subheadline.weight(.semibold))
            if let topic = status.topic {
                Text(topic)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button("Copy Topic") {
                    UIPasteboard.general.string = topic
                    info = "Copied."
                }
                .font(.subheadline)
            }
            Text("Leave the server as \(BMNtfy.serverLabel(status.server)), and allow notifications when ntfy asks.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// ntfy if it is here; the App Store page if it isn't.
    private func openNtfy() {
        UIApplication.shared.open(BMNtfy.appScheme) { opened in
            if !opened { UIApplication.shared.open(BMNtfy.appStore) }
        }
    }

    // MARK: Talking to BookMaster

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let latest = try await BookMaster.shared.fetchNtfy()
            status = latest
            AppPrefs.ntfyActive = latest.isOn
            error = nil
        } catch {
            if status == nil { self.error = "Couldn’t reach BookMaster." }
        }
    }

    private func change(link: String? = nil, preview: Bool? = nil, rotate: Bool = false) async {
        working = true
        defer { working = false }
        do {
            let latest = try await BookMaster.shared.setNtfy(link: link, preview: preview, rotate: rotate)
            status = latest
            AppPrefs.ntfyActive = latest.isOn
            error = nil
            info = rotate ? "New topic made. Add it to ntfy." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        do {
            try await BookMaster.shared.testNtfy()
            info = "Sent. It should arrive in a moment."
            error = nil
        } catch {
            info = nil
            self.error = error.localizedDescription
        }
    }

    private func turnOff() async {
        working = true
        defer { working = false }
        do {
            try await BookMaster.shared.removeNtfy()
            status = BMNtfyStatus(available: true, server: status?.server, topic: nil, link: nil, preview: false)
            AppPrefs.ntfyActive = false
            error = nil
            info = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
