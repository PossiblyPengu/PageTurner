import SwiftUI

/// Quest Log's private room inside the chat screen. The room is end-to-end encrypted and keeps its own
/// passphrase, so it is BookMaster's web chat — the same code Quest Log uses — shown here alone
/// (`BMChat.questLogRoom`); Pageturner never holds the key. The page is kept alive between visits, so
/// once the passphrase is given it stays given until the app closes, and the sign-in is the in-app
/// browser's (one for all three web apps).
@MainActor
final class BMQuestLogRoomPage {
    static let shared = BMQuestLogRoomPage()
    let page = BMWebPage(app: .bookmaster)
    private init() {}

    /// Signed out or unlinked: the room is locked again (its passphrase lived in the page) and the next reader starts fresh.
    func forget() {
        page.unload()
        if page.webView.window != nil { page.open(BMChat.questLogRoom) }
    }
}

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

struct BMQuestLogRoomView: View {
    private let page = BMQuestLogRoomPage.shared.page
    /// A new identity takes the shared web view back when another copy of the chat has had it meanwhile.
    @State private var hostID = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            BMWebHost(page: page).id(hostID)
            if page.isLoading, page.progress < 1 {
                ProgressView(value: page.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.ptAccent)
            }
            if let failure = page.failure {
                failureView(failure)
            } else if !page.isLoading, page.currentURL != nil, !BMChat.isQuestLogRoom(page.currentURL) {
                // sent to sign in (or anywhere else): the way back to the room, once that is done
                backToRoom
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            hostID = UUID()
            page.openIfNeeded(BMChat.questLogRoom)
            Notifier.shared.noteQuestLogOpened()
        }
        // what comes in while the room is the one in view is seen as it comes
        .onChange(of: Notifier.shared.questLogUnread) { _, waiting in
            if waiting { Notifier.shared.noteQuestLogOpened() }
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open Quest Log’s room", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { page.open(BMChat.questLogRoom) }
                .ptButtonStyle(prominent: true)
        }
        .background(Color(.systemBackground))
    }

    /// Shown over the page's top edge while it is not the room: signing in to BookMaster comes first, once.
    private var backToRoom: some View {
        HStack(spacing: 10) {
            Text("Sign in to BookMaster, then open the room.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Open the room") { page.open(BMChat.questLogRoom) }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
