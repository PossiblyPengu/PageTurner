import SwiftUI

/// BookMaster's own pages as Pageturner's tabs — the shelf, Together and the stats — and its chat: the very pages
/// the web shows (`BMWebTab`), drawn alone, so they are the same everywhere and there is no second copy of them
/// here to keep in step. Pageturner draws what is around a page: the tab bar, the notifications bell, the settings
/// button, the banners and the floating chat button.
struct BMWebTabView: View {
    let tab: BMWebTab
    @Environment(AppRouter.self) private var router
    @State private var showInbox = false
    private let bookMaster = BookMaster.shared
    private let inbox = BMInboxStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if bookMaster.isLinked {
                    BMWebTabContent(tab: tab)
                } else {
                    ScrollView { BMLinkPrompt().padding(16).ptReadableWidth() }
                        .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showInbox) { BMInboxView() }
            .toolbar { barItems }
        }
    }

    /// The notifications bell and the ways into Kindred and Quest Log on the Together tab; Settings on every one.
    @ToolbarContentBuilder
    private var barItems: some ToolbarContent {
        if bookMaster.isLinked, tab == .together {
            ToolbarItem(placement: .topBarLeading) {
                let unread = inbox.unreadCount
                Button { showInbox = true } label: {
                    Image(systemName: unread > 0 ? "bell.badge.fill" : "bell")
                }
                .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(BMWebApp.allCases) { app in
                        Button { router.browser = BMWebLaunch(app: app, url: nil) } label: {
                            Label(app.name, systemImage: app.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("Open an app")
            }
        }
        SettingsToolbarItem(router: router)
    }
}

/// A BookMaster page in a web view of its own, kept alive so a tab is where it was left: a progress bar while it
/// loads, and the way to try again when it could not.
struct BMWebTabContent: View {
    let tab: BMWebTab

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        let page = BMWebPages.shared.tab(tab)
        return ZStack(alignment: .top) {
            BMWebHost(page: page)
            if page.isLoading, page.progress < 1 {
                ProgressView(value: page.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.ptAccent)
            }
            if let failure = page.failure {
                failureView(failure, page: page)
            }
        }
        .onAppear { page.openIfNeeded() }
    }

    private func failureView(_ message: String, page: BMWebPage) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open BookMaster", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { page.reload() }
                .ptButtonStyle(prominent: true)
        }
        .background(Color(.systemBackground))
    }
}

/// The chat as a full page over the app, for the floating button: BookMaster's chat page — the shared room, with
/// Quest Log's own beside it — with a way back.
struct BMChatScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cameFrom = "library"
    private let notifier = Notifier.shared

    var body: some View {
        NavigationStack {
            BMWebTabContent(tab: .chat)
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
        }
        .onAppear {
            if BookMaster.shared.place != "chat" { cameFrom = BookMaster.shared.place }
            BookMaster.shared.place = "chat"
        }
        .onDisappear { BookMaster.shared.place = cameFrom }
        // what comes in while the chat is the one in view is read as it comes: its dot stays away
        .onChange(of: notifier.chatUnread?.id) { _, id in
            if id != nil { notifier.noteChatOpened() }
        }
    }
}

/// One of the suite's web apps, full screen over the app: where a tapped notification, or a link from a page into
/// Kindred or Quest Log, leads.
struct BMWebBrowserScreen: View {
    let launch: BMWebLaunch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BMWebBrowserView(launch: launch)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// What a BookMaster tab shows before an account is linked: the pitch, and the way in.
struct BMLinkPrompt: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ptAccent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your reading life, together")
                    .font(.title2.bold())
                Text("Link BookMaster to bring your shelf, streaks, goals, quotes and the other reader into Pageturner.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Progress follows you between devices", systemImage: "arrow.triangle.2.circlepath")
                Label("Goals, streaks and your year in books", systemImage: "chart.bar.fill")
                Label("A shared shelf and chat with your reading partner", systemImage: "person.2.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button { router.showLink = true } label: {
                Label("Link BookMaster", systemImage: "link")
                    .frame(maxWidth: .infinity)
                    // hug the button's edges at giant text instead of breaking mid-title
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.75)
            }
            .buttonStyle(.borderedProminent)
            .tint(.ptAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
