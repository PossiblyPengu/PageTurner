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
    @State private var room: BMChatRoom?
    @State private var messages: [BMChatMessage] = []
    @State private var complete = true
    @State private var draft = ""
    @State private var sending = false
    @State private var loading = true
    @State private var loadingOlder = false
    @State private var error: String?
    /// The newest message already reported as read, so each is reported once.
    @State private var reported = 0
    @FocusState private var focused: Bool

    private let pollSeconds: UInt64 = 5

    var body: some View {
        Group {
            if BookMaster.shared.isLinked {
                VStack(spacing: 0) {
                    thread
                    Divider()
                    composer
                }
            } else {
                ScrollView { BMLinkPrompt().padding(16) }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(room?.partner?.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { BookMaster.shared.place = "chat" }
        .onDisappear { BookMaster.shared.place = "bookmaster" }
        .task(id: BookMaster.shared.isLinked) { await run() }
        .onChange(of: scenePhase) { _, phase in
            active = phase == .active
            // back from the background: what came meanwhile, now
            if active { Task { await refresh() } }
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
                    if messages.isEmpty, !loading {
                        Text(emptyText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                            .padding(.horizontal, 24)
                    }
                    ForEach(rows) { row in
                        line(row)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .ptReadableWidth()
            }
            .refreshable { await refresh() }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, _ in
                withAnimation { proxy.scrollTo(bottom, anchor: .bottom) }
            }
            .overlay {
                if loading, messages.isEmpty { ProgressView() }
            }
        }
    }

    private let bottom = "chat-bottom"

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

    private func bubble(_ m: BMChatMessage, mine: Bool) -> some View {
        let fill: Color = mine ? .accentColor : Color(uiColor: .secondarySystemGroupedBackground)
        let ink: Color = mine ? .white : .primary
        return Text(m.body)
            .font(.body)
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
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
            .disabled(sending || BMChat.sendable(draft) == nil)
            .accessibilityLabel("Send")
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
        await refresh()
        loading = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
            guard !Task.isCancelled, active else { continue }
            await refresh()
        }
    }

    private func refresh() async {
        do {
            let latest = try await BookMaster.shared.fetchChat()
            guard !Task.isCancelled else { return }
            room = latest
            messages = BMChat.replacingNewest(messages, with: latest.messages)
            if messages.count == latest.messages.count { complete = latest.complete }
            error = nil
            await reportRead()
        } catch {
            guard !Task.isCancelled else { return }
            if room == nil { self.error = "Couldn’t reach BookMaster. Pull down to try again." }
        }
    }

    /// Looking at the room is reading it.
    private func reportRead() async {
        guard active, let room, let newest = messages.last?.id,
              newest > room.read.mine, newest > reported else { return }
        reported = newest
        do { try await BookMaster.shared.markChatRead(upTo: newest) } catch { reported = 0 }
    }

    private func loadOlder() async {
        guard let first = messages.first, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await BookMaster.shared.fetchChat(before: first.id)
            messages = BMChat.merge(page.messages, messages)
            complete = page.complete
        } catch {
            self.error = "Couldn’t load earlier messages."
        }
    }

    // MARK: Writing

    private func send() async {
        guard let text = BMChat.sendable(draft), !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let sent = try await BookMaster.shared.sendChat(text)
            draft = ""
            error = nil
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
            // the words stay in the box
            self.error = error.localizedDescription
        }
    }

    private func remove(_ m: BMChatMessage) async {
        do {
            try await BookMaster.shared.removeChat(id: m.id)
            messages.removeAll { $0.id == m.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
