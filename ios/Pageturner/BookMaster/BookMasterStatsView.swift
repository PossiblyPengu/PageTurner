import SwiftUI

/// The numbers tab: the momentum card, goals (made and removed here, like the
/// web's goal card), the last month's heatmap, what is on the go, the badge
/// wall, the year's wrap — and the account itself: name, the library export
/// and the way out.
struct BookMasterStatsView: View {
    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var library: LibraryStore
    @State private var overview: BMOverview?
    @State private var stats: BMStatBlock?
    @State private var achievements: [BMAchievementFull]?
    @State private var goalSheet = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var shareItem: ShareItem?
    @State private var importing = false
    @State private var confirmUnlink = false
    @State private var error: String?
    /// Good news — an import's tally, not a failure.
    @State private var notice: String?
    @State private var loading = true
    /// A write that failed (remove goal, rename, export) — an alert, since the footer can be off-screen.
    @State private var actionError: String?
    @State private var removingGoal: String?
    @State private var allBadges = false
    /// The last refresh missed something while older numbers are still on screen.
    @State private var refreshFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    if BookMaster.shared.isLinked {
                        linkedBody
                    } else {
                        BMLinkPrompt()
                        BMDeviceStatsCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .ptReadableWidth()
            }
            .ptSoftScrollEdges()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationDestination(for: Push.self) { push in
                switch push {
                case .wrapped: BookMasterWrappedView()
                }
            }
            .navigationTitle("Stats")
            .toolbar { SettingsToolbarItem(router: router) }
            .sheet(isPresented: $goalSheet) { BMGoalSheet { Task { await load() } } }
            .sheet(isPresented: $importing) {
                BMImportSheet { message in
                    notice = message
                    Task { await load() }
                }
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .alert("Unlink BookMaster?", isPresented: $confirmUnlink) {
                Button("Unlink", role: .destructive) {
                    BookMaster.shared.unlink()
                    library.clearBookMasterFields()
                    Notifier.shared.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The link is forgotten and queued pushes with it. Nothing on BookMaster is deleted.")
            }
            .refreshable { await load() }
            .task(id: BookMaster.shared.isLinked) { await load() }
        }
        // the stack, not the list: a pushed pane is still the Stats tab
        .onAppear { BookMaster.shared.place = "bookmaster" }
        .onDisappear { BookMaster.shared.place = "library" }
        .confirmationDialog("Remove this goal?", isPresented: Binding(
            get: { removingGoal != nil }, set: { if !$0 { removingGoal = nil } }),
                            titleVisibility: .visible) {
            Button("Remove goal", role: .destructive) {
                if let id = removingGoal { Task { await removeGoal(id) } }
                removingGoal = nil
            }
            Button("Cancel", role: .cancel) { removingGoal = nil }
        }
        .alert("BookMaster", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private enum Push: String, Hashable { case wrapped }

    @ViewBuilder
    private var linkedBody: some View {
        statusCard
        if loading, overview == nil, stats == nil {
            ProgressView("Bringing BookMaster up to date…")
                .frame(maxWidth: .infinity, minHeight: 120)
                .bmCard()
        } else {
            momentumCard
            if let stats { levelCard(stats) }
            goalsCard
            if let stats, !stats.recentActivity.isEmpty { heatmapCard(stats.recentActivity) }
            if let stats, !stats.currentlyReading.isEmpty { readingCard(stats.currentlyReading) }
            achievementsCard
            wrappedRow
            profileCard
        }
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bmCard()
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled { self.notice = nil }
                }
        }
        if refreshFailed, overview != nil || stats != nil {
            Label("Couldn’t refresh — showing the last numbers.", systemImage: "wifi.exclamationmark")
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

    // MARK: Status

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(Color.ptAccent.opacity(0.14))
                Image(systemName: "book.closed.fill").foregroundStyle(Color.ptAccent)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(BookMaster.shared.user?.displayName ?? BookMaster.shared.user?.username ?? "BookMaster")
                    .font(.headline)
                Label(BookMaster.shared.syncEnabled ? "Reading is syncing" : "Sync is paused",
                      systemImage: BookMaster.shared.syncEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(BookMaster.shared.syncEnabled ? Color.green : Color.orange)
            }
            Spacer()
            Toggle("Sync", isOn: Binding(
                get: { BookMaster.shared.syncEnabled },
                set: { BookMaster.shared.syncEnabled = $0 }))
                .labelsHidden()
        }
        .bmCard()
    }

    // MARK: Momentum & level

    @ViewBuilder
    private var momentumCard: some View {
        if let overview {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    BMMetric(value: "\(Int(overview.stats.currentStreak))",
                             label: "day streak", icon: "flame.fill", color: .orange)
                    Divider().frame(height: 48)
                    BMMetric(value: "\(Int(overview.stats.booksFinished))",
                             label: "finished", icon: "books.vertical.fill", color: .ptAccent)
                    Divider().frame(height: 48)
                    BMMetric(value: BMFormat.duration(minutes: Int(overview.stats.minutesRead)),
                             label: "time read", icon: "clock.fill", color: .blue)
                }
                if let achievement = overview.recentAchievements.first {
                    Label("\(achievement.icon ?? "🏆")  \(achievement.name)", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .bmCard()
        }
    }

    private func levelCard(_ stats: BMStatBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Level \(stats.level)").font(.headline)
                Spacer()
                Text("\(Int(stats.xp)) XP")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let next = stats.xpForNext {
                    Text("· \(Int(next)) to go")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(1, max(0, stats.xpProgress ?? 0))).tint(.ptAccent)
        }
        .bmCard()
    }

    // MARK: Goals

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Goals", systemImage: "target").font(.headline)
                Spacer()
                Button { goalSheet = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New goal")
            }
            let goals = overview?.goals ?? []
            if goals.isEmpty {
                Text("No goals yet — a number to chase lives here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(goals, id: \.stableId) { goal in
                    goalRow(goal)
                }
            }
        }
        .bmCard()
    }

    private func goalRow(_ goal: BMGoal) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(goal.label ?? BMFormat.goalLabel(goal.type))
                        .font(.subheadline.weight(.medium))
                    if goal.type == "monthly_books", let month = goal.month, let year = goal.year {
                        Text("for \(Self.monthName(month)) \(String(year))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(Int(goal.current)) of \(Int(goal.target ?? 0))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let id = goal.id {
                    Button(role: .destructive) { removingGoal = id } label: {
                        Image(systemName: "trash").font(.caption)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove goal")
                }
            }
            ProgressView(value: min(1, max(0, goal.progress))).tint(.ptAccent)
        }
    }

    private func removeGoal(_ id: String) async {
        do {
            try await BookMaster.shared.removeGoal(id: id)
            overview?.goals.removeAll { $0.id == id }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Heatmap

    /// The last five weeks, darker where more pages landed — the same grid
    /// the web's ReadingHeatmap draws, fed by the same session days.
    private func heatmapCard(_ days: [BMActivityDay]) -> some View {
        let cells = Self.cells(days)
        return VStack(alignment: .leading, spacing: 12) {
            Text("The last five weeks").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells, id: \.date) { cell in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(cell.color)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel(cell.label)
                        .accessibilityHidden(cell.label.isEmpty)
                }
            }
        }
        .bmCard()
    }

    /// One square per day ending today, in week columns — nil pages is a quiet day.
    private struct HeatCell {
        let date: String
        let color: Color
        let label: String
    }

    private static func cells(_ days: [BMActivityDay]) -> [HeatCell] {
        let byDate = Dictionary(days.map { ($0.sessionDate, $0.pages ?? 0) }, uniquingKeysWith: +)
        let peak = max(days.map(\.pages).compactMap { $0 }.max() ?? 0, 1)
        var out: [HeatCell] = []
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // empty squares first, so the first column is the calendar's first weekday
        if let first = calendar.date(byAdding: .day, value: -34, to: Date()) {
            let pad = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
            for i in 0..<pad {
                out.append(HeatCell(date: "pad\(i)", color: Color.clear, label: ""))
            }
        }
        for back in (0..<35).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let key = formatter.string(from: day)
            let pages = byDate[key] ?? 0
            let heat = min(pages / peak, 1)
            out.append(HeatCell(
                date: key,
                color: pages == 0 ? Color(.tertiarySystemFill) : Color.ptAccent.opacity(0.25 + 0.75 * heat),
                label: "\(key): \(Int(pages)) pages"))
        }
        return out
    }

    // MARK: On the go

    private func readingCard(_ rows: [BMReadingRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On the go").font(.headline)
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            if let author = row.author, !author.isEmpty { Text(author) }
                            if row.format == "audio" { Text("· audio") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let percent = row.percent {
                        Text("\(Int(percent.rounded()))%")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .bmCard()
    }

    // MARK: Achievements

    @ViewBuilder
    private var achievementsCard: some View {
        if let achievements, !achievements.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Achievements", systemImage: "trophy.fill").font(.headline)
                    Spacer()
                    Text("\(achievements.filter(\.earned).count) of \(achievements.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let ordered = achievements.filter(\.earned) + achievements.filter { !$0.earned }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(allBadges ? ordered : Array(ordered.prefix(8))) { badge in
                        VStack(spacing: 4) {
                            Text(badge.icon ?? "🏆").font(.title2)
                            if !badge.earned, let progress = badge.progress, progress > 0 {
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(badge.earned ? 1 : 0.5)
                        .accessibilityLabel(badge.name ?? "Achievement")
                        .accessibilityValue(badge.earned ? "Earned" : "Locked")
                    }
                }
                if achievements.count > 8 {
                    Button(allBadges ? "Show fewer" : "Show all \(achievements.count)") { allBadges.toggle() }
                        .font(.subheadline)
                }
            }
            .bmCard()
        }
    }

    // MARK: Wrapped & profile

    private var wrappedRow: some View {
        NavigationLink(value: Push.wrapped) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.headline).foregroundStyle(.pink)
                    .frame(width: 32, height: 32)
                    .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("The year so far").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Account", systemImage: "person.crop.circle").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BookMaster.shared.user?.displayName ?? "—").font(.subheadline.weight(.medium))
                    Text("@\(BookMaster.shared.user?.username ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename") {
                    newName = BookMaster.shared.user?.displayName ?? ""
                    renaming = true
                }
                .font(.subheadline)
            }
            .alert("Display name", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { Task { await rename() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name the other reader and notices see.")
            }
            Divider()
            HStack(spacing: 10) {
                Button { Task { await export("csv") } } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }
                .buttonStyle(.bordered)
                Button { Task { await export("json") } } label: {
                    Label("Export JSON", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            Button { importing = true } label: {
                Label("Import from Goodreads", systemImage: "square.and.arrow.down")
            }
            .font(.subheadline)
            Divider()
            Button(role: .destructive) { confirmUnlink = true } label: {
                Label("Unlink BookMaster", systemImage: "link.badge.plus")
            }
            .font(.subheadline)
        }
        .bmCard()
    }

    private func rename() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try await BookMaster.shared.updateProfile(displayName: name)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The export comes back as bytes — parked in a temp file for the share sheet.
    private func export(_ format: String) async {
        do {
            let data = try await BookMaster.shared.exportData(format: format)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bookmaster-export.\(format == "csv" ? "csv" : "json")")
            try data.write(to: url)
            shareItem = ShareItem(url: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private static func monthName(_ month: Int) -> String {
        let names = ["", "January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November", "December"]
        return names.indices.contains(month) ? names[month] : "\(month)"
    }

    private func load() async {
        guard BookMaster.shared.isLinked else {
            overview = nil; stats = nil; achievements = nil
            error = nil; loading = false
            return
        }
        async let o = try? await BookMaster.shared.fetchOverview()
        async let s = try? await BookMaster.shared.fetchStats()
        async let a = try? await BookMaster.shared.fetchAchievements()
        let (overview, stats, achievements) = await (o, s, a)
        guard !Task.isCancelled else { return }
        if let overview { self.overview = overview }
        if let stats { self.stats = stats }
        if let achievements { self.achievements = achievements }
        refreshFailed = overview == nil || stats == nil || achievements == nil
        error = (overview == nil && stats == nil && self.overview == nil && self.stats == nil)
            ? "BookMaster can’t be reached right now." : nil
        loading = false
    }
}
