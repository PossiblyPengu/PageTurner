import SwiftUI

/// Instant notifications through Bark, for the settings form.
///
/// A sideloaded app has no push entitlement, so iOS cannot deliver real push to Pageturner itself. The
/// free Bark app can — it has a push service of its own — and, unlike ntfy.sh, nothing limits BookMaster's
/// shared server address. The reader installs Bark and pastes the key it shows; BookMaster sends every
/// notification from all four apps there. The key is a secret, so it is never shown back — only its last
/// four characters.
struct BMBarkSection: View {
    @State private var status: BMBarkStatus?
    @State private var loading = true
    @State private var working = false
    @State private var pasted = ""
    @State private var changingKey = false
    @State private var info: String?
    @State private var error: String?
    @State private var confirmOff = false

    var body: some View {
        Section {
            content
            if let info { Text(info).font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Instant notifications")
        } footer: {
            Text("Through the free Bark app. The words of a notification pass through \(BMBark.serverLabel(status?.server)).")
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
            Text("Pageturner is installed outside the App Store, so iOS can’t push to it. The free Bark app can: BookMaster sends every notification — chat, suggestions, Kindred and Quest Log — to it, and Bark shows it at once, even when Pageturner is closed.")
                .font(.footnote).foregroundStyle(.secondary)
            steps
            keyField
            Button { Task { await save() } } label: {
                if working { ProgressView() } else { Text("Turn On") }
            }
            .disabled(working || BMBark.key(from: pasted) == nil)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Install Bark").font(.subheadline.weight(.semibold))
            Button("Open Bark") { openBark() }
                .font(.subheadline)
            Text("2. Copy the key").font(.subheadline.weight(.semibold))
            Text("Bark shows an example address, like https://api.day.app/ followed by a long code. The long code is your key. Allow notifications when Bark asks.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("3. Paste it here").font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 2)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Paste your Bark key", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            if !pasted.isEmpty, BMBark.key(from: pasted) == nil {
                Text("That doesn’t look like a Bark key — it is the long code of letters and numbers.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    // MARK: On

    @ViewBuilder
    private func onBody(_ status: BMBarkStatus) -> some View {
        LabeledContent("Device", value: "Key ending \(status.keyHint ?? "—")")
        Button { Task { await test() } } label: {
            Label("Send a Test Notification", systemImage: "bell.badge")
        }
        .disabled(working)
        Toggle("Open Pageturner when tapped", isOn: Binding(
            get: { status.opensPageturner },
            set: { on in Task { await save(link: on ? "pageturner" : "web") } }))
        Text("Off: a tap opens the page on the web instead. If tapping a notification doesn’t open Pageturner, turn this off.")
            .font(.footnote).foregroundStyle(.secondary)
        Toggle("Show the words of a chat message", isOn: Binding(
            get: { status.preview },
            set: { on in Task { await save(preview: on) } }))
        Text("Off: only who wrote. The key is the only secret — anyone who has it can send to your phone.")
            .font(.footnote).foregroundStyle(.secondary)
        if changingKey {
            keyField
            Button("Save Key") { Task { await save() } }
                .disabled(working || BMBark.key(from: pasted) == nil)
        } else {
            Button("Change Key…") { changingKey = true; pasted = "" }
        }
        Button("Turn Off", role: .destructive) { confirmOff = true }
            .alert("Turn off instant notifications?", isPresented: $confirmOff) {
                Button("Turn Off", role: .destructive) { Task { await turnOff() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("BookMaster stops sending to Bark. Pageturner goes back to checking now and then in the background.")
            }
    }

    /// Bark if it is here; the App Store page if it isn't.
    private func openBark() {
        UIApplication.shared.open(BMBark.appScheme) { opened in
            if !opened { UIApplication.shared.open(BMBark.appStore) }
        }
    }

    // MARK: Talking to BookMaster

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let latest = try await BookMaster.shared.fetchBark()
            status = latest
            AppPrefs.barkActive = latest.isOn
            error = nil
        } catch {
            if status == nil { self.error = "Couldn’t reach BookMaster." }
        }
    }

    /// Set the key pasted (or leave it), and/or change how it behaves.
    private func save(link: String? = nil, preview: Bool? = nil) async {
        working = true
        defer { working = false }
        let key = (link == nil && preview == nil) ? BMBark.key(from: pasted) : nil
        do {
            let latest = try await BookMaster.shared.setBark(key: key, link: link, preview: preview)
            status = latest
            AppPrefs.barkActive = latest.isOn
            error = nil
            if key != nil {
                pasted = ""
                changingKey = false
                info = "Saved. Send a test to check it."
            } else {
                info = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        working = true
        defer { working = false }
        do {
            try await BookMaster.shared.testBark()
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
            try await BookMaster.shared.removeBark()
            status = BMBarkStatus(available: true, server: status?.server, configured: false, keyHint: nil, link: nil, preview: false)
            AppPrefs.barkActive = false
            error = nil
            info = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
