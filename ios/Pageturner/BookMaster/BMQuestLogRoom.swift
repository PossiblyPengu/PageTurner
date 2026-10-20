import SwiftUI

/// The room's tab and the other one: "Us" and "Quest Log" (a lock on it, and a blue square while it has
/// something new).
struct BMChatTabs: View {
    @Binding var tab: BMChatTab
    private let notifier = Notifier.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BMChatTab.allCases) { item in
                button(item)
            }
        }
        .padding(3)
        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
        .fixedSize()
    }

    private func button(_ item: BMChatTab) -> some View {
        let selected = tab == item
        let waiting = item == .questLog && !selected && notifier.questLogUnread
        return Button { tab = item } label: {
            HStack(spacing: 5) {
                if item == .questLog { Image(systemName: "lock.fill").font(.caption2) }
                Text(item.title).font(.subheadline.weight(.semibold))
                if waiting { BMDot(tone: .questLog, size: 8) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? Color(uiColor: .systemBackground) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(waiting ? "\(item.title), something new" : item.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Quest Log's private chat, as a screen of Pageturner's own: the same thread and box as the shared room, behind the
/// Quest Log passphrase. The words are opened and sealed on this iPhone (`BMQuestLogChat`); this is only the face.
struct BMQuestLogRoomView: View {
    /// The shared room as last read: BookMaster says there which part of Quest Log this reader plays, and who the other is.
    let room: BMChatRoom?

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var sending = false
    @State private var atBottom = true
    @State private var newBelow = false
    @FocusState private var focused: Bool

    private let chat = BMQuestLogChat.shared
    private let bottom = "ql-chat-bottom"

    private var role: BMQuestLog.Role? { chat.role(serverSays: room?.questLogRole) }
    private var partner: String { room?.partner?.displayName ?? "Them" }

    var body: some View {
        content
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                chat.loadIfNeeded()
                Notifier.shared.noteQuestLogOpened()
            }
            // what comes in while the room is the one in view is seen as it comes
            .onChange(of: Notifier.shared.questLogUnread) { _, waiting in
                if waiting { Notifier.shared.noteQuestLogOpened() }
            }
            .task(id: chat.unlocked && scenePhase == .active) {
                if chat.unlocked, scenePhase == .active { await chat.poll() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !chat.unlocked {
            BMQuestLogLockScreen()
        } else if let role {
            VStack(spacing: 0) {
                header(role)
                thread(role)
                    // the composer floats: the transcript scrolls under it
                    .safeAreaInset(edge: .bottom, spacing: 4) { composer(role) }
            }
        } else if room == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            rolePicker
        }
    }

    // MARK: The bar above

    private func header(_ role: BMQuestLog.Role) -> some View {
        HStack(spacing: 10) {
            Label("Encrypted — only this passphrase opens it", systemImage: "lock.open.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if room?.questLogRole == nil {
                Button("Change role") { chat.choose(nil) }
                    .font(.caption.weight(.semibold))
            }
            Button("Lock") { chat.lock() }
                .font(.caption.weight(.semibold))
                .tint(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .ptReadableWidth()
    }

    private var rolePicker: some View {
        VStack(spacing: 14) {
            Text("Which are you in Quest Log?")
                .font(.headline)
            Text("Asked once on this iPhone. The role you choose is how your messages are written.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ForEach(BMQuestLog.Role.allCases) { option in
                Button(option.title) { chat.choose(option) }
                    .ptButtonStyle(prominent: option == .giver)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The thread

    private func thread(_ role: BMQuestLog.Role) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    status
                    ForEach(BMQuestLog.rows(chat.entries)) { row in
                        line(row, mine: row.entry.role == role)
                    }
                    if let error = chat.actionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 8)
                    }
                    bottomMarker
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .ptReadableWidth()
            }
            .refreshable { await chat.refresh() }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .ptSoftScrollEdges()
            .onChange(of: chat.entries.last?.id) { _, _ in follow(proxy, role: role) }
            .overlay(alignment: .bottom) { newMessageChip(proxy) }
            .overlay {
                if !chat.ready, chat.loadError == nil { ProgressView() }
            }
        }
    }

    private var bottomMarker: some View {
        Color.clear.frame(height: 1).id(bottom)
            .onAppear {
                atBottom = true
                newBelow = false
            }
            .onDisappear { atBottom = false }
    }

    /// A new message takes you to the bottom when you were there, or when it is yours; otherwise it waits below,
    /// with a note, so the place you were reading is kept.
    private func follow(_ proxy: ScrollViewProxy, role: BMQuestLog.Role) {
        let mine = chat.entries.last.map { $0.role == role } ?? false
        if atBottom || mine {
            withAnimation { proxy.scrollTo(bottom, anchor: .bottom) }
        } else {
            newBelow = true
        }
    }

    @ViewBuilder
    private func newMessageChip(_ proxy: ScrollViewProxy) -> some View {
        if newBelow, !atBottom {
            Button {
                withAnimation { proxy.scrollTo(bottom, anchor: .bottom) }
            } label: {
                Label("New message", systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .ptGlassCapsule(interactive: true)
            }
            .padding(.bottom, 8)
        }
    }

    /// What stands in for an empty thread: the failure to load, or the room being empty — only once it is known,
    /// so a failed load never claims there is nothing here.
    @ViewBuilder
    private var status: some View {
        if !chat.ready, let error = chat.loadError {
            VStack(spacing: 10) {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await chat.refresh() } }
            }
            .padding(.top, 60)
            .padding(.horizontal, 24)
        } else if chat.ready, chat.entries.isEmpty {
            Text("Nothing here yet. What you write shows up in Quest Log’s chat, and the other way round.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 60)
                .padding(.horizontal, 24)
        }
    }

    private func line(_ row: BMQuestLog.Row, mine: Bool) -> some View {
        VStack(spacing: 2) {
            if let day = row.day { dayHeader(day) }
            HStack {
                if mine { Spacer(minLength: 48) }
                column(row, mine: mine)
                if !mine { Spacer(minLength: 48) }
            }
            .padding(.top, row.head && row.day == nil ? 6 : 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func dayHeader(_ day: String) -> some View {
        Text(day.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }

    /// One message's bubble, with the other's name above it and its time below it where a burst begins and ends.
    private func column(_ row: BMQuestLog.Row, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if row.head, !mine {
                Text(partner)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            bubble(row.entry, mine: mine)
            if row.tail {
                Text(BMChat.clock(row.entry.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    /// The bubble's long-press is the menu with Delete (your own) and Copy.
    private func bubble(_ entry: BMQuestLog.Entry, mine: Bool) -> some View {
        let fill: Color = mine ? .accentColor : Color(uiColor: .secondarySystemGroupedBackground)
        let ink: Color = mine ? .white : .primary
        return Group {
            if entry.failed {
                Label("Can’t be opened with this passphrase", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(entry.failed ? Color(uiColor: .tertiarySystemFill) : fill,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { bubbleMenu(entry, mine: mine) }
    }

    @ViewBuilder
    private func bubbleMenu(_ entry: BMQuestLog.Entry, mine: Bool) -> some View {
        if mine {
            Button(role: .destructive) { Task { await chat.remove(entry) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if !entry.failed {
            Button { UIPasteboard.general.string = entry.text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: The box

    private func composer(_ role: BMQuestLog.Role) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if BMChat.isTooLong(draft) {
                Text("Too long — a message can be up to \(BMQuestLog.maxLength.formatted()) characters.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Write something private…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button { Task { await send(role) } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(sending || !chat.ready || BMQuestLog.sendable(draft) == nil)
                .accessibilityLabel("Send")
            }
        }
        .padding(8)
        .ptGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .ptReadableWidth()
    }

    private func send(_ role: BMQuestLog.Role) async {
        guard let text = BMQuestLog.sendable(draft), !sending else { return }
        sending = true
        defer { sending = false }
        // cleared first, so a second tap sees an empty box; put back if it did not go
        let kept = draft
        draft = ""
        if await !chat.send(text, as: role) { draft = kept }
    }
}

/// Asking for the passphrase: what the room is, the box, and whether to keep it unlocked here.
struct BMQuestLogLockScreen: View {
    @State private var passphrase = ""
    @State private var remember = true
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let chat = BMQuestLogChat.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                    .frame(width: 52, height: 52)
                    .background(Color.orange.opacity(0.15), in: Circle())
                VStack(spacing: 6) {
                    Text("Quest Log’s private chat")
                        .font(.title3.weight(.semibold))
                    Text("End-to-end encrypted: only the Quest Log passphrase opens it, and this is the same conversation you see inside Quest Log. Messages are opened and sealed on this iPhone; BookMaster only passes them along.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                SecureField("Quest Log passphrase", text: $passphrase)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { Task { await unlock() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Toggle("Keep it unlocked on this iPhone", isOn: $remember)
                    .font(.subheadline)
                if let message = error ?? chat.lockNotice {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button { Task { await unlock() } } label: {
                    Text(busy ? "Checking…" : "Unlock").frame(maxWidth: .infinity)
                }
                .ptButtonStyle(prominent: true)
                .disabled(passphrase.isEmpty || busy)
                Text("Kept only in this iPhone’s Keychain, never in a backup or on another device — and gone when you lock the room, unlink BookMaster, or sign out of the apps.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func unlock() async {
        guard !passphrase.isEmpty, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        if let failure = await chat.unlock(passphrase, remember: remember) {
            error = failure
        } else {
            passphrase = ""
        }
    }
}
