import SwiftUI

/// The suite's chat: one room for the two of you, the same one BookMaster's
/// Chat page, Kindred and Quest Log's main chat open onto. Written here it is
/// tagged as Pageturner's; written elsewhere it shows where it came from.
///
/// While the screen is open it asks for what is new every few seconds, and
/// tells the server how far you have read, so the other reader's "Seen" lights
/// and the unread dot goes out of every app. (Quest Log's private, encrypted
/// chat is not here — it is reached from BookMaster's Chat page with its own
/// passphrase.)
struct BMChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Kept as state: a long-running task would otherwise read the phase it started in.
    @State private var active = true
    /// Whether this screen is the one in front. Reading is only reported from here: a chat that is pushed
    /// but covered (another tab, a sheet) has not been looked at.
    @State private var visible = false
    /// Which room is showing: the shared one (native, below), or Quest Log's own (the web's, in a page).
    @State private var tab: BMChatTab = .us
    /// Where the reader was before the chat opened — put back when it closes (the Together tab, or any other
    /// screen, when it came as the floating button's full page).
    @State private var cameFrom = "bookmaster"
    @State private var room: BMChatRoom?
    @State private var messages: [BMChatMessage] = []
    @State private var complete = true
    @State private var draft = ""
    @State private var sending = false
    @State private var loading = true
    @State private var loadingOlder = false
    /// Why the room could not be loaded; shown in its place while nothing has loaded.
    @State private var loadError: String?
    /// Why a send or a take-back failed; it stays until the next try or the next keystroke.
    @State private var actionError: String?
    /// The words put back in the box after a failed send, so that putting them back is not mistaken for typing.
    @State private var restoredDraft: String?
    /// The newest message already reported as read, so each is reported once.
    @State private var reported = 0
    /// Counts the sends and take-backs that have finished. A poll that began before one finished carries
    /// the room as it was, and must not undo it.
    @State private var edits = 0
    @State private var refreshing = false
    /// Whether the bottom of the thread is in view — so a message arriving while you read history
    /// does not take you away from it.
    @State private var atBottom = true
    @State private var newBelow = false
    @FocusState private var focused: Bool

    private let pollSeconds: UInt64 = 5

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        lifecycle(content)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(room?.partner?.displayName ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if BookMaster.shared.isLinked {
                    ToolbarItem(placement: .principal) { BMChatTabs(tab: $tab) }
                }
            }
    }

    private var content: some View {
        Group {
            if BookMaster.shared.isLinked {
                switch tab {
                case .us:
                    VStack(spacing: 0) {
                        thread
                        Divider()
                        composer
                    }
                case .questLog:
                    BMQuestLogRoomView()
                }
            } else {
                ScrollView { BMLinkPrompt().padding(16) }
            }
        }
    }

    private func lifecycle<V: View>(_ view: V) -> some View {
        view
            .onAppear {
                visible = true
                if BookMaster.shared.place != "chat" { cameFrom = BookMaster.shared.place }
                BookMaster.shared.place = "chat"
            }
            .onDisappear {
                visible = false
                BookMaster.shared.place = cameFrom
            }
            .hidesChatButton()
            .task(id: BookMaster.shared.isLinked) { await run() }
            .onChange(of: scenePhase) { _, phase in
                active = phase == .active
                // back from the background: what came meanwhile, now
                if active, visible { Task { await refresh() } }
            }
            .onChange(of: draft) { _, now in
                if now == restoredDraft { restoredDraft = nil } else { actionError = nil }
            }
            .onChange(of: tab) { _, now in
                focused = false
                // back to the shared room: what came while the other was showing, now
                if now == .us, active, visible { Task { await refresh() } }
            }
    }

    // MARK: The thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !complete, !messages.isEmpty {
                        Button(loadingOlder ? "Loading…" : "Earlier messages") { Task { await loadOlder() } }
                            .font(.footnote)
                            .disabled(loadingOlder)
                            .padding(.vertical, 8)
                    }
                    status
                    ForEach(rows) { row in
                        line(row)
                    }
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.triangle")
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
            .refreshable { await refresh() }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, _ in follow(proxy) }
            .overlay(alignment: .bottom) { newMessageChip(proxy) }
            .overlay {
                if loading, messages.isEmpty { ProgressView() }
            }
        }
    }

    private let bottom = "chat-bottom"

    /// The end of the thread, whose being on screen is "you are at the bottom".
    private var bottomMarker: some View {
        Color.clear.frame(height: 1).id(bottom)
            .onAppear {
                atBottom = true
                newBelow = false
            }
            .onDisappear { atBottom = false }
    }

    /// A new message takes you to the bottom when you were there, or when it is yours; otherwise it waits
    /// below, with a note, so the place you were reading is kept.
    private func follow(_ proxy: ScrollViewProxy) {
        let mine = messages.last.map { $0.userId == room?.me.id } ?? false
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
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(.bottom, 8)
        }
    }

    /// What stands in for an empty thread: the failure to load, or the room being empty — only once
    /// the room is known, so a failed load never claims you are alone in it.
    @ViewBuilder
    private var status: some View {
        if room == nil, !loading {
            VStack(spacing: 10) {
                Text(loadError ?? "Couldn’t reach BookMaster.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await refresh() } }
            }
            .padding(.top, 60)
            .padding(.horizontal, 24)
        } else if room != nil, messages.isEmpty {
            Text(emptyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 60)
                .padding(.horizontal, 24)
        }
    }

    private var emptyText: String {
        room?.partner.map { "Nothing yet. Say hello to \($0.displayName) — it shows up in BookMaster, Kindred and Quest Log too." }
            ?? "You are the only one here so far. This fills in once your partner has a BookMaster account."
    }

    private var rows: [BMChat.Row] { BMChat.rows(messages) }

    private var lastMineId: Int? {
        guard let me = room?.me.id else { return nil }
        return messages.last { $0.userId == me }?.id
    }

    private func line(_ row: BMChat.Row) -> some View {
        let m = row.message
        let mine = m.userId == room?.me.id
        return VStack(spacing: 2) {
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

    /// One message's bubble, with its name above it and its time below it where a burst begins and ends.
    private func column(_ row: BMChat.Row, mine: Bool) -> some View {
        let m = row.message
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if row.head, !mine {
                Text(speaker(m))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            bubble(m, mine: mine)
            if row.tail {
                Text(footnote(for: m, mine: mine))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    /// The bubble's long-press is the menu with Delete and Copy. (Text selection is left off: on a
    /// selectable text the long-press belongs to the selection, and the menu would never appear.)
    private func bubble(_ m: BMChatMessage, mine: Bool) -> some View {
        let fill: Color = mine ? .accentColor : Color(uiColor: .secondarySystemGroupedBackground)
        let ink: Color = mine ? .white : .primary
        return Text(m.body)
            .font(.body)
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contextMenu { bubbleMenu(m, mine: mine) }
    }

    @ViewBuilder
    private func bubbleMenu(_ m: BMChatMessage, mine: Bool) -> some View {
        if mine {
            Button(role: .destructive) { Task { await remove(m) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        Button { UIPasteboard.general.string = m.body } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    /// "Sam", or "Sam · via Kindred" when it was written elsewhere.
    private func speaker(_ m: BMChatMessage) -> String {
        BMChat.via(m.app).map { "\(m.name) · via \($0)" } ?? m.name
    }

    /// The time, and under your own last message whether it has been seen.
    private func footnote(for m: BMChatMessage, mine: Bool) -> String {
        var parts = [BMChat.clock(m.date)]
        if mine, let via = BMChat.via(m.app) { parts.append("via \(via)") }
        if mine, m.id == lastMineId,
           let status = BMChat.seenLabel(
            lastMineId: m.id, theirsRead: room?.read.theirs ?? 0, hasPartner: room?.partner != nil) {
            parts.append(status)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if BMChat.isTooLong(draft) {
                Text("Too long — a message can be up to \(BMChat.maxLength.formatted()) characters.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(sending || room == nil || BMChat.sendable(draft) == nil)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .ptReadableWidth()
        .background(.bar)
    }

    // MARK: Fetching

    /// Open on the newest page, then keep up while the screen is here.
    private func run() async {
        guard BookMaster.shared.isLinked else {
            loading = false
            return
        }
        visible = true
        await refresh()
        loading = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
            guard !Task.isCancelled, active else { continue }
            await refresh()
        }
    }

    private func refresh() async {
        // one at a time: two in flight can land out of order, and the older would overwrite the newer
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let stamp = edits
        do {
            let latest = try await BookMaster.shared.fetchChat(limit: BMChat.pageSize)
            // a send or a take-back finished while this was out: it carries the room as it was, so it is
            // not applied; the next poll, a few seconds on, will include the change
            guard !Task.isCancelled, stamp == edits else { return }
            room = latest
            messages = BMChat.replacingNewest(messages, with: latest.messages)
            if messages.count == latest.messages.count { complete = latest.complete }
            loadError = nil
            await reportRead()
        } catch {
            guard !Task.isCancelled else { return }
            if room == nil { loadError = BMChat.explain(error) }
        }
    }

    /// Looking at the room is reading it — when it is the screen in front.
    private func reportRead() async {
        // reading is only reported from the shared room, while it is the one showing
        guard active, visible, tab == .us, let room, let newest = messages.last?.id,
              newest > room.read.mine, newest > reported else { return }
        reported = newest
        do { try await BookMaster.shared.markChatRead(upTo: newest) } catch { reported = 0 }
    }

    private func loadOlder() async {
        guard let first = messages.first, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await BookMaster.shared.fetchChat(before: first.id, limit: BMChat.pageSize)
            messages = BMChat.merge(page.messages, messages)
            complete = page.complete
        } catch {
            actionError = "Couldn’t load earlier messages."
        }
    }

    // MARK: Writing

    private func send() async {
        guard let text = BMChat.sendable(draft), !sending, room != nil else { return }
        sending = true
        actionError = nil
        // cleared now, so what is typed while this goes is the next message and is not wiped when it lands
        draft = ""
        defer { sending = false }
        do {
            let sent = try await BookMaster.shared.sendChat(text)
            edits += 1
            messages = BMChat.merge(messages, [sent])
            if let current = room {
                // sending is reading: what you answer, you have seen
                room = BMChatRoom(
                    messages: current.messages, me: current.me, partner: current.partner,
                    read: BMChatRead(mine: max(current.read.mine, sent.id), theirs: current.read.theirs),
                    unread: 0, complete: current.complete)
            }
            reported = max(reported, sent.id)
        } catch {
            // the words come back, unless something new has already been typed
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                restoredDraft = text
                draft = text
            }
            actionError = BMChat.explain(error)
        }
    }

    private func remove(_ m: BMChatMessage) async {
        do {
            try await BookMaster.shared.removeChat(id: m.id)
            edits += 1
            messages.removeAll { $0.id == m.id }
        } catch {
            actionError = BMChat.explain(error)
        }
    }
}
