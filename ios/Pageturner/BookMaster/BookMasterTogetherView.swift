import SwiftUI

/// The other reader: what you are both reading, how the year compares, where
/// they are across the suite, and the suggestions in flight both ways. The
/// Together page of BookMaster, whole.
struct BookMasterTogetherView: View {
    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var library: LibraryStore
    @State private var together: BMTogether?
    @State private var partnerShelf: BMPartnerShelf?
    @State private var stats: BMStatBlock?
    @State private var overview: BMOverview?
    @State private var error: String?
    /// A suggestion that could not be answered — told by an alert, since the error line is at the foot of a long page.
    @State private var answerError: String?
    @State private var loading = true
    /// Suggestion ids with a reply in flight — both buttons wait for it.
    @State private var answering: Set<String> = []
    /// The last refresh missed while older data is still on screen.
    @State private var refreshFailed = false
    @State private var showChat = false
    /// The notifications list, pushed from the bell.
    @State private var showInbox = false
    /// The in-app browser, when one of the suite's web apps is open.
    @State private var browser: BMWebLaunch?

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        NavigationStack {
            reacting(destinations(page))
        }
        // the stack, not the list: a pushed pane is still the Together tab
        .onAppear { BookMaster.shared.place = "bookmaster" }
        .onDisappear { BookMaster.shared.place = "library" }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if BookMaster.shared.isLinked {
                    linkedBody
                } else {
                    BMLinkPrompt()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .ptReadableWidth()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Together")
    }

    /// Where the page leads: the chat, the in-app browser, and the buttons that open them.
    private func destinations<V: View>(_ content: V) -> some View {
        content
            .navigationDestination(isPresented: $showChat) { BMChatView() }
            .navigationDestination(isPresented: $showInbox) { BMInboxView() }
            .navigationDestination(item: $browser) { BMWebBrowserView(launch: $0) }
            .toolbar { barItems }
    }

    /// The notifications bell and Settings. (The chat is not up here — the floating button reaches it from every
    /// screen, and the card below does.)
    @ToolbarContentBuilder
    private var barItems: some ToolbarContent {
        if BookMaster.shared.isLinked {
            ToolbarItem(placement: .topBarLeading) {
                let unread = BMInboxStore.shared.unreadCount
                Button { showInbox = true } label: {
                    Image(systemName: unread > 0 ? "bell.badge.fill" : "bell")
                }
                .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
            }
        }
        SettingsToolbarItem(router: router)
    }

    /// Loading, and going where a tapped notification (`pageturner://open`) said.
    private func reacting<V: View>(_ content: V) -> some View {
        content
            .refreshable { await load() }
            .alert("Couldn’t answer", isPresented: Binding(
                get: { answerError != nil }, set: { if !$0 { answerError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(answerError ?? "")
            }
            .task(id: BookMaster.shared.isLinked) { await load() }
            .onChange(of: router.suiteTarget, initial: true) { _, target in openTarget(target) }
            // the simulator run asks for the list without a tap
            .onChange(of: router.showInbox, initial: true) { _, on in
                guard on else { return }
                router.showInbox = false
                showInbox = true
            }
    }

    // MARK: The page

    @ViewBuilder
    private var linkedBody: some View {
        // what is waiting for you comes first — a suggestion to answer, something new in another app…
        if let together, !together.nudges.isEmpty {
            nudgeCard(together.nudges)
        }
        if let together, !together.notices.isEmpty {
            noticeCard(together.notices)
        }
        // …then the ways into the rest of the suite…
        chatCard
        appsCard
        // …then the two of you.
        if partnerShelf?.partner != nil, overview != nil {
            comparisonCard
        }
        // the web's side-by-side pair, stacked for a phone
        memberCard(
            name: "You",
            online: true,
            level: stats?.level,
            streak: stats?.currentStreak,
            apps: together?.you?.apps,
            readingRows: mineReadingBooks,
            finishedRows: mineFinishedBooks)
        if let partner = together?.partner {
            memberCard(
                name: partnerShelf?.partner?.name ?? partner.name,
                online: partner.online,
                level: partnerShelf?.partner?.level,
                streak: partnerShelf?.stats?.currentStreak,
                apps: partner.apps,
                readingRows: partnerReadingBooks,
                finishedRows: partnerFinishedBooks)
            if let shelf = partnerShelf, shelf.partner != nil, !shelf.books.isEmpty {
                shelfCard(shelf)
            }
        } else if !loading, together != nil {
            // only a reply that said "no partner" is the solo state; a failed load is not
            aloneCard
        }
        if let together, !together.sent.isEmpty {
            sentCard(together.sent)
        }
        if loading, together == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        }
        if refreshFailed, together != nil {
            Label("Couldn’t refresh — showing the last data.", systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bmCard()
        }
        if let error {
            Label(error, systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bmCard()
        }
    }

    // MARK: Chat

    /// The notice that says a message is waiting — until you have opened it (from here or the floating button).
    private var unreadChat: BMNotice? { Notifier.shared.chatUnread }

    /// Go where a tapped notification said: the native chat, or the browser at its page.
    private func openTarget(_ target: BMDeepLink.Target?) {
        guard let target else { return }
        router.suiteTarget = nil
        guard BookMaster.shared.isLinked else { return }
        switch target {
        case .chat:
            openChat()
        case let .web(app, url):
            browser = BMWebLaunch(app: app, url: url)
        }
    }

    private func openChat() {
        Notifier.shared.noteChatOpened()
        showChat = true
    }

    /// The way into the shared room, with the newest line when one waits.
    private var chatCard: some View {
        Button { openChat() } label: {
            HStack(spacing: 12) {
                Image(systemName: unreadChat == nil ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat").font(.headline).foregroundStyle(.primary)
                    Text(unreadChat?.text ?? "Talk to \(together?.partner?.name ?? "the other reader") — shared with BookMaster, Kindred and Quest Log")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if unreadChat != nil {
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bmCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Derived rows

    /// What a member card draws — either side's row shape flattened to one.
    private struct MemberBook: Identifiable {
        var id: String
        var title: String
        var author: String?
        var coverUrls: [URL] = []
        var percent: Double? = nil
        var touched: String? = nil
        var rating: Int? = nil
        var finished: String? = nil
    }

    /// What you have on the go — the stats route's own list of it.
    private var mineReadingBooks: [MemberBook] {
        (stats?.currentlyReading ?? []).map {
            MemberBook(id: $0.id, title: $0.title, author: $0.author,
                       coverUrls: bmCoverURLs(coverUrl: $0.coverUrl, isbn: nil, openLibraryId: nil),
                       percent: $0.percent, touched: $0.updatedAt)
        }
    }

    /// Your last few finishes, off the shelf the Books tab already pulled.
    private var mineFinishedBooks: [MemberBook] {
        BookMaster.shared.shelfRows
            .filter { $0.status == "read" }
            .sorted { ($0.finishDate ?? "") > ($1.finishDate ?? "") }
            .prefix(5)
            .map {
                MemberBook(id: $0.id, title: $0.title, author: $0.author,
                           rating: $0.rating, finished: $0.finishDate)
            }
    }

    /// Their books on the go — the shelf lists them all; the together reply's
    /// single freshest one stands in when the shelf fetch itself missed.
    private var partnerReadingBooks: [MemberBook] {
        let rows = (partnerShelf?.books ?? [])
            .filter { $0.status == "reading" }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        if !rows.isEmpty {
            return rows.map {
                MemberBook(id: $0.id, title: $0.title ?? "Untitled", author: $0.author,
                           coverUrls: bmCoverURLs(coverUrl: $0.coverUrl, isbn: $0.isbn, openLibraryId: $0.openLibraryId),
                           percent: $0.percent, touched: $0.updatedAt)
            }
        }
        return together?.partner?.reading.map { r in
            [MemberBook(id: "partner-reading", title: r.title, author: r.author,
                        percent: r.percent, touched: r.updatedAt)]
        } ?? []
    }

    private var partnerFinishedBooks: [MemberBook] {
        (partnerShelf?.books ?? [])
            .filter { $0.status == "read" }
            .sorted { ($0.finishDate ?? "") > ($1.finishDate ?? "") }
            .prefix(5)
            .map {
                MemberBook(id: $0.id, title: $0.title ?? "Untitled", author: $0.author,
                           rating: $0.rating, finished: $0.finishDate)
            }
    }

    // MARK: Suggested for you

    private func nudgeCard(_ nudges: [BMNudge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Suggested for you", systemImage: "sparkles").font(.headline)
                Spacer()
                Text("\(nudges.count)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.ptAccent, in: Capsule())
            }
            ForEach(Array(nudges.enumerated()), id: \.element.id) { n, nudge in
                HStack(alignment: .top, spacing: 12) {
                    nudgeCover(nudge)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nudge.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        if let author = nudge.author {
                            Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        (Text(nudge.fromName).foregroundStyle(Color.ptAccent)
                            + Text(nudge.note.map { ": “\($0)”" } ?? " thought you would like this")
                                .foregroundStyle(.secondary))
                            .font(.footnote)
                        HStack(spacing: 10) {
                            Button("Add to want to read") { Task { await answer(nudge, accept: true) } }
                                .buttonStyle(.borderedProminent)
                            Button("Dismiss") { Task { await answer(nudge, accept: false) } }
                                .buttonStyle(.bordered)
                            if answering.contains(nudge.id) { ProgressView() }
                        }
                        .controlSize(.small)
                        .disabled(answering.contains(nudge.id))
                        .padding(.top, 4)
                    }
                }
                .onAppear {
                    prefetchCovers(nudges.dropFirst(n + 10).prefix(8).map {
                        bmCoverURLs(coverUrl: $0.coverUrl, isbn: $0.isbn, openLibraryId: $0.openLibraryId)
                    })
                }
            }
        }
        .bmCard()
    }

    /// The first url of each cover chain into `CoverFetch`'s caches — the
    /// suggestion rows further down are warmed before they scroll into view.
    private func prefetchCovers(_ chains: [[URL]]) {
        CoverFetch.prefetch(chains.compactMap(\.first))
    }

    /// The jacket the suggestion named: the bridge's stored cover, then Open Library's.
    private func nudgeCover(_ nudge: BMNudge) -> some View {
        RemoteCover(urls: bmCoverURLs(coverUrl: nudge.coverUrl, isbn: nudge.isbn, openLibraryId: nudge.openLibraryId))
        .frame(width: 44, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: The year, side by side

    /// "{year} so far" — the web's comparison table, a row per measure with
    /// whoever leads it in the accent colour.
    private var comparisonCard: some View {
        let year = partnerShelf?.year ?? overview?.year
        let mine: [(String, Double)] = [
            ("Books this year", Double(overview?.booksThisYear ?? 0)),
            ("Pages this year", overview?.pagesThisYear ?? 0),
            ("Current streak", stats?.currentStreak ?? 0),
            ("Longest streak", stats?.longestStreak ?? 0),
            ("Books all time", stats?.booksFinished ?? 0),
            ("Level", Double(stats?.level ?? 1)),
        ]
        let theirs: [Double] = [
            Double(partnerShelf?.booksThisYear ?? 0),
            partnerShelf?.pagesThisYear ?? 0,
            partnerShelf?.stats?.currentStreak ?? 0,
            partnerShelf?.stats?.longestStreak ?? 0,
            partnerShelf?.stats?.booksFinished ?? 0,
            Double(partnerShelf?.partner?.level ?? 1),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(year.map { "\(String($0)) so far" } ?? "The year so far", systemImage: "trophy")
                    .font(.headline).foregroundStyle(Color.ptAccent)
                Spacer()
            }
            HStack {
                Spacer()
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(Color.ptAccent)
                    .frame(width: 64, alignment: .trailing)
                Text(partnerShelf?.partner?.name ?? "Them")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
            }
            ForEach(Array(zip(mine, theirs).enumerated()), id: \.offset) { entry in
                let ((label, m), t) = entry.element
                HStack {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text((m > t ? "▲ " : "") + Self.fmt(m)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(m > t ? Color.ptAccent : .primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 64, alignment: .trailing)
                    Text((t > m ? "▲ " : "") + Self.fmt(t)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(t > m ? Color.ptAccent : .primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("You \(Self.fmt(m)), \(partnerShelf?.partner?.name ?? "them") \(Self.fmt(t))")
            }
        }
        .bmCard()
    }

    /// Streaks wear "d"; the rest are plain counts.
    private static func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? "\(Int(v))" : String(format: "%.1f", v)
    }

    // MARK: A reader's card

    /// One member card: name and level, the suite line, what is on the go and
    /// what just finished — the web's MemberShelf, native.
    private func memberCard(
        name: String,
        online: Bool,
        level: Int?,
        streak: Double?,
        apps: [String: BMAppBeat]?,
        readingRows: [MemberBook],
        finishedRows: [MemberBook]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(online ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 10, height: 10)
                            .accessibilityLabel(online ? "Online" : "Offline")
                        Text(name).font(.headline)
                    }
                    if let level {
                        Text("Level \(level) · \(bmLevelTitle(level))")
                            .font(.caption).foregroundStyle(Color.ptAccent)
                    }
                    if let line = BMSuite.whereaboutsLine(apps) {
                        Label(line, systemImage: online ? "iphone" : "moon.zzz")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let streak, streak > 0 {
                    Label("\(Int(streak))d", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("READING NOW")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if readingRows.isEmpty {
                    Text("Nothing on the go.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(readingRows) { book in
                        HStack(spacing: 10) {
                            memberCover(book)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                if let author = book.author {
                                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let percent = book.percent {
                                    HStack(spacing: 6) {
                                        ProgressView(value: min(max(percent / 100, 0), 1))
                                            .tint(.ptAccent)
                                        Text("\(Int(percent.rounded()))%")
                                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            if let ago = BMSuite.timeAgo(book.touched) {
                                Text(ago).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("RECENTLY FINISHED")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if finishedRows.isEmpty {
                    Text("Nothing finished yet.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(finishedRows) { book in
                        HStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(book.title).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 0)
                            if let rating = book.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 5)))
                                    .font(.caption2).foregroundStyle(Color.ptAccent)
                            }
                            if let date = book.finished {
                                Text(BMSuite.timeAgo(date) ?? date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .bmCard()
    }

    private func memberCover(_ book: MemberBook) -> some View {
        RemoteCover(urls: book.coverUrls)
        .frame(width: 36, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    /// A two-reader shelf with one seat filled.
    private var aloneCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2").font(.title2).foregroundStyle(.secondary)
            Text("Reading for two").font(.headline)
            Text("When the second account signs up, their shelf appears here alongside yours.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .bmCard()
    }

    // MARK: Their shelf

    /// What they read and how they rated it, never their review — the first
    /// few rows, with the whole shelf a tap away.
    private func shelfCard(_ shelf: BMPartnerShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(shelf.partner?.name ?? "Their")’s shelf").font(.headline)
                Spacer()
                Text("\(shelf.books.count)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shelf.books.prefix(6)) { book in
                HStack(spacing: 10) {
                    shelfThumb(book)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title ?? "Untitled").font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            if let status = book.status { Text(BMShelf.label(forStatus: status)) }
                            if let percent = book.percent, book.status == "reading" {
                                Text("· \(Int(percent.rounded()))%")
                            }
                            if let rating = book.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 5)))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if shelf.books.count > 6 {
                NavigationLink {
                    BMPartnerShelfList(shelf: shelf)
                } label: {
                    Label("All \(shelf.books.count) books", systemImage: "books.vertical")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .bmCard()
    }

    private func shelfThumb(_ book: BMPartnerBook) -> some View {
        RemoteCover(
            urls: bmCoverURLs(coverUrl: book.coverUrl, isbn: book.isbn, openLibraryId: book.openLibraryId),
            icon: book.format == "audio" ? "headphones" : "book.closed")
        .frame(width: 40, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Suggestions of yours still out with them.
    private func sentCard(_ sent: [BMSentNudge]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting on them").font(.headline)
            ForEach(sent) { nudge in
                VStack(alignment: .leading, spacing: 4) {
                    Text(nudge.title).font(.subheadline.weight(.medium))
                    Text("To \(nudge.toName) · \(nudge.status)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let note = nudge.note, !note.isEmpty { Text("“\(note)”").font(.callout) }
                }
            }
        }
        .bmCard()
    }

    /// What the rest of the suite wants this reader to see.
    private func noticeCard(_ notices: [BMNotice]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for you").font(.headline)
            ForEach(notices) { notice in
                if canOpen(notice) {
                    Button { open(notice) } label: {
                        HStack(spacing: 8) {
                            noticeLine(notice)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    noticeLine(notice)
                }
            }
        }
        .bmCard()
    }

    /// A dot on an app's tile while something from it is waiting — Quest Log's blue and square.
    @ViewBuilder
    private func waitingDot(for app: BMWebApp) -> some View {
        if (together?.notices ?? []).contains(where: { $0.app == app.rawValue }) {
            BMDot(
                tone: BMSuite.dotTone(forApp: app.rawValue), size: 10,
                ring: Color(uiColor: .tertiarySystemGroupedBackground))
                .offset(x: 8, y: -6)
        }
    }

    private func waitingLabel(for app: BMWebApp) -> String {
        let n = (together?.notices ?? []).filter { $0.app == app.rawValue }.count
        return n == 0 ? "Open \(app.name)" : "Open \(app.name), \(n) waiting"
    }

    /// A notice with its dot — Quest Log's blue and square, the others' round — and the app it is from.
    private func noticeLine(_ notice: BMNotice) -> some View {
        let from = BMSuite.names[notice.app] ?? notice.app
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            BMDot(tone: BMSuite.dotTone(forApp: notice.app))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.text).font(.subheadline).multilineTextAlignment(.leading)
                Text(from).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(from): \(notice.text)")
    }

    // MARK: The other apps

    /// BookMaster, Kindred and Quest Log, opened in here.
    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The other apps").font(.headline)
            HStack(spacing: 10) {
                ForEach(BMWebApp.allCases) { app in
                    Button { browser = BMWebLaunch(app: app) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: app.symbol).font(.title3)
                                .overlay(alignment: .topTrailing) { waitingDot(for: app) }
                            Text(app.name).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(waitingLabel(for: app))
                }
            }
            Text("They open here, signed in once for all three.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bmCard()
    }

    /// A notice opens its page — the chat in the app's own screen, anything else in the browser.
    private func canOpen(_ notice: BMNotice) -> Bool {
        notice.id.hasPrefix(BMChat.noticePrefix)
            || BMWebApp.destination(noticeApp: notice.app, path: notice.path) != nil
    }

    private func open(_ notice: BMNotice) {
        if notice.id.hasPrefix(BMChat.noticePrefix) {
            openChat()
        } else if let target = BMWebApp.destination(noticeApp: notice.app, path: notice.path) {
            browser = BMWebLaunch(app: target.app, url: target.url)
        }
    }

    // MARK: Fetching

    private func load() async {
        guard BookMaster.shared.isLinked else {
            together = nil
            partnerShelf = nil
            stats = nil
            overview = nil
            loading = false
            return
        }
        async let t = try? await BookMaster.shared.fetchTogether()
        async let p = try? await BookMaster.shared.fetchPartnerShelf()
        async let s = try? await BookMaster.shared.fetchStats()
        async let o = try? await BookMaster.shared.fetchOverview()
        let (together, partnerShelf, stats, overview) = await (t, p, s, o)
        guard !Task.isCancelled else { return }
        if let together {
            self.together = together
            Notifier.shared.noteSeen(together)
        }
        if let partnerShelf { self.partnerShelf = partnerShelf }
        if let stats { self.stats = stats }
        if let overview { self.overview = overview }
        refreshFailed = together == nil || partnerShelf == nil || stats == nil || overview == nil
        error = (together == nil && self.together == nil)
            ? "BookMaster can’t be reached right now." : nil
        loading = false
        // the "You" card's finished list rides on the shelf the Books tab owns —
        // fetch it once if nobody has yet
        if BookMaster.shared.shelfRows.isEmpty {
            await BookMaster.shared.pullShelf(into: library)
        }
    }

    private func answer(_ nudge: BMNudge, accept: Bool) async {
        guard answering.insert(nudge.id).inserted else { return }
        defer { answering.remove(nudge.id) }
        do {
            try await BookMaster.shared.answerNudge(id: nudge.id, accept: accept)
            error = nil
            together?.nudges.removeAll { $0.id == nudge.id }
            if let together { Notifier.shared.noteSeen(together) }
        } catch {
            answerError = error.localizedDescription
        }
    }
}

/// Their whole shelf — the rows the card only previews.
private struct BMPartnerShelfList: View {
    let shelf: BMPartnerShelf

    var body: some View {
        List {
            ForEach(shelf.books) { book in
                HStack(spacing: 12) {
                    RemoteCover(
                        urls: bmCoverURLs(coverUrl: book.coverUrl, isbn: book.isbn, openLibraryId: book.openLibraryId),
                        icon: book.format == "audio" ? "headphones" : "book.closed")
                    .frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title ?? "Untitled").font(.body.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            if let status = book.status { Text(BMShelf.label(forStatus: status)) }
                            if let percent = book.percent, book.status == "reading" {
                                Text("· \(Int(percent.rounded()))%")
                            }
                            if let rating = book.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 5)))
                            }
                            if let author = book.author { Text("· \(author)") }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("\(shelf.partner?.name ?? "Their")’s shelf")
        .navigationBarTitleDisplayMode(.inline)
    }
}
