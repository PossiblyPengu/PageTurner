import ReadiumNavigator
import ReadiumShared
import SwiftUI

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showContents = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showVoices = false
    /// The scrubber's value while the finger is on it (or until the page catches up).
    @State private var scrubbing: Double?
    @AppStorage("readerShowsTimeLeft") private var showsTimeLeft = false
    @State private var dragging = false
    @State private var scrubTask: Task<Void, Never>?
    @State private var exportFile: ShareItem?
    @State private var copied = false
    @State private var contentsTab: ContentsTab = .chapters

    /// The way out of the book: the Reading tab is the book's home, so leaving
    /// it is a tab switch, not a dismissal.
    private let onBack: () -> Void

    init(book: Book, library: LibraryStore, onBack: @escaping () -> Void) {
        // a book still being read aloud after its reader was left comes back as the same reader
        _model = StateObject(wrappedValue: ReadAloudHost.shared.take(for: book) ?? ReaderModel(book: book, library: library))
        self.onBack = onBack
    }

    /// The page's own light or dark — the chrome, the sheets and the status bar follow it.
    private var scheme: ColorScheme { model.activeSettings.theme.isDark ? .dark : .light }

    var body: some View {
        // grouped, so no one expression is a long chain the compiler has to solve at once
        sheets(lifecycle(layout))
            .preferredColorScheme(scheme)
    }

    private var layout: some View {
        ZStack {
            content
            // the evening light and the ruler sit over the page, under the controls
            ReaderVeil(dim: model.settings.dim, warmth: model.settings.warmth)
            if model.settings.ruler, model.phase == .ready {
                ReadingRuler(y: Binding(get: { model.settings.rulerY }, set: { model.settings.rulerY = $0 }))
            }
            if model.phase == .ready {
                VStack(spacing: 8) {
                    if model.showChrome {
                        header.transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if model.showChrome {
                        if let label = model.backLabel {
                            backChip(label)
                        }
                        if let index = model.searchHitIndex {
                            searchStepper(index: index, count: model.searchResults.count)
                        }
                        if let readAloud = model.readAloud, readAloud.isActive {
                            ReadAloudBar(
                                readAloud: readAloud,
                                rate: model.settings.speechRate,
                                onInteraction: model.revealChrome,
                                onRate: { model.cycleRate(); model.revealChrome() },
                                onVoice: { model.holdChrome(); showVoices = true },
                                onStop: { model.stopReadAloud(); model.revealChrome() }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            footer.transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .statusBarHidden(!model.showChrome)
        // the book fills the tab while it is read — the bar returns with the rest of the chrome
        .tabBarChrome(model.showChrome)
        // a bookmark or highlight added is felt, not just seen
        .sensoryFeedback(trigger: model.book.bookmarks.count) { old, new in new > old ? .impact(weight: .light) : .selection }
        .sensoryFeedback(trigger: model.book.highlights.count) { old, new in new > old ? .success : nil }
        .ptAnimation(.smooth(duration: 0.25), value: model.showChrome)
        .ptAnimation(.smooth(duration: 0.25), value: model.readAloud?.isActive)
        .ptAnimation(.smooth(duration: 0.25), value: model.backLabel)
    }

    /// The screen stays on while a book is open and on screen (unless the reader switched that off).
    private func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on && model.settings.keepAwake
    }

    /// Opening, saving, and the sitting that BookMaster is told about.
    private func lifecycle<V: View>(_ content: V) -> some View {
        content
            .task {
                await model.open()
                // coming back to the tab starts a new sitting; beginSession is a no-op while one runs
                if model.phase == .ready { model.beginSession() }
            }
            .onChange(of: model.settings) { _, _ in model.applySettings() }
            .onChange(of: model.settings.keepAwake) { _, _ in keepAwake(true) }
            // a theme that follows the clock: look again every few minutes
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in model.refreshNight() }
            .onAppear {
                BookMaster.shared.place = "reader"
                keepAwake(true)
                ReadAloudHost.shared.show(model)
            }
            .onDisappear {
                keepAwake(false)
                model.flushSave()
                model.endSession()
                // narration under way goes on, with the now-playing strip to control it; anything else stops
                ReadAloudHost.shared.leave(model)
                BookMaster.shared.place = "library"
            }
            // a sitting ends when the app leaves the screen — not whenever it is next opened.
            // .inactive is its own case: locking the screen can park the app there without a
            // .background ever arriving (keep-awake or a live read-aloud session), so the
            // position lands on disk there too — only the session end waits for .background.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive: model.flushSave()
                case .background: model.flushSave(); model.endSession(); keepAwake(false)
                case .active: model.beginSession(); model.refreshAwake(); keepAwake(true)
                default: break
                }
            }
            // once the page has caught up with the scrubber it lets go
            .onChange(of: model.book.progression) { _, _ in
                if !dragging { scrubbing = nil }
            }
            #if DEBUG
            // CI simulator run: put a sheet up once the book has opened (Debug/DebugScenario.swift)
            .task {
                guard let sheet = DebugScenario.readerSheet else { return }
                // the ones that act on the open book wait for it to open
                let needsBook = ["jump", "pdfsearch", "readaloud", "readaloudaway"].contains(sheet)
                try? await Task.sleep(nanoseconds: needsBook ? 7_000_000_000 : 3_000_000_000)
                switch sheet {
                case "pdfsearch":
                    model.search("fox")
                    showSearch = true
                case "contents": showContents = true
                case "settings": showSettings = true
                case "voices": showVoices = true
                case "search": showSearch = true
                case "hidechrome": model.toggleChrome()
                // read aloud with the highlights and voice the launch asks for, to see them on the page
                case "readaloud":
                    DebugScenario.configureReadAloud(&model.settings)
                    model.applySettings()   // pushes a debug scroll-mode switch into the navigator
                    model.toggleReadAloud()
                // read aloud, then leave the reader: the voice must go on, with the now-playing strip over the library
                case "readaloudaway":
                    DebugScenario.configureReadAloud(&model.settings)
                    model.applySettings()
                    model.toggleReadAloud()
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    onBack()
                // a jump far ahead: the Back chip should appear
                case "jump": model.go(toProgression: 0.8)
                case "footnote":
                    model.footnote = Footnote(
                        text: "Ishmael is the narrator; the name is an invitation, not a claim.",
                        label: "1", link: ReadiumShared.Link(href: "chapter-1.xhtml"))
                case "highlight":
                    model.editingHighlight = Highlight(
                        locatorJSON: "{}", text: "It is a way I have of driving off the spleen and regulating the circulation.",
                        color: "blue", note: "Love this line.", chapter: "Chapter 1", progression: 0.03)
                default: break
                }
            }
            #endif
    }

    private func sheets<V: View>(_ content: V) -> some View {
        panels(content)
            .sheet(isPresented: $showVoices, onDismiss: model.revealChrome) {
                voiceSheet.preferredColorScheme(scheme)
            }
    }

    private func panels<V: View>(_ content: V) -> some View {
        content
            // a sheet is its own presentation: it doesn't inherit the reader's colour scheme
            .sheet(isPresented: $showContents, onDismiss: model.revealChrome) {
                contentsSheet.preferredColorScheme(scheme)
            }
            .sheet(isPresented: $showSettings, onDismiss: model.revealChrome) {
                settingsSheet.preferredColorScheme(scheme)
            }
            .sheet(isPresented: $showSearch, onDismiss: model.revealChrome) {
                searchSheet.preferredColorScheme(scheme)
            }
            .sheet(item: $model.footnote) { note in
                FootnoteSheet(note: note) { model.goToFootnote(note) }
                    .preferredColorScheme(scheme)
            }
            .sheet(item: $model.editingHighlight) { highlight in
                HighlightEditorSheet(
                    highlight: highlight,
                    canQuote: BookMaster.shared.isLinked,
                    onSave: { color, note in model.updateHighlight(highlight.id, color: color, note: note) },
                    onDelete: { model.removeHighlight(highlight) },
                    onQuote: { await model.quoteHighlight(highlight) },
                    bookTitle: model.book.title,
                    bookAuthor: model.book.author,
                    cardTheme: model.activeSettings.theme
                )
                .preferredColorScheme(scheme)
            }
            .alert("Pageturner", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.notice ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).ignoresSafeArea())
        case .ready:
            if let controller = model.navigatorController {
                NavigatorRepresentable(controller: controller)
                    .ignoresSafeArea()
            }
        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                HStack(spacing: 12) {
                    Button("Try Again") { model.retry() }
                        .buttonStyle(.bordered)
                    Button("Back to Library") { onBack() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
        }
    }

    /// Back, the title, and the page's tools — floating on glass over the page.
    private var header: some View {
        PTGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                PTIconButton(systemImage: "chevron.left", label: "Back to library") { onBack() }

                VStack(spacing: 0) {
                    Text(model.book.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if let chapter = secondLine {
                        Text(chapter)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .ptGlassCapsule()
                .accessibilityElement(children: .combine)

                HStack(spacing: 0) {
                    if model.isSearchable {
                        toolButton("magnifyingglass", label: "Search in book") { model.holdChrome(); showSearch = true }
                    }
                    toolButton(
                        model.isCurrentLocationBookmarked ? "bookmark.fill" : "bookmark",
                        label: model.isCurrentLocationBookmarked ? "Remove bookmark" : "Add bookmark"
                    ) { model.toggleBookmark(); model.revealChrome() }
                    toolButton("list.bullet", label: "Contents, bookmarks and highlights") { model.holdChrome(); showContents = true }
                }
                .padding(.horizontal, 4)
                .ptGlassCapsule()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
    }

    /// Text settings, how far along you are, and read aloud.
    private var footer: some View {
        PTGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                PTIconButton(systemImage: "textformat.size", label: "Reading settings") { model.holdChrome(); showSettings = true }

                HStack(spacing: 10) {
                    progressLabel
                    Slider(
                        value: Binding(get: { shownProgress }, set: { value in
                            scrubbing = value
                            // VoiceOver / Switch Control adjust without a drag: navigate once they settle
                            if !dragging { settleScrub(at: value) }
                        }),
                        in: 0...1,
                        onEditingChanged: { editing in
                            dragging = editing
                            scrubTask?.cancel()
                            if editing { model.holdChrome() } else { model.revealChrome() }
                            guard !editing, let target = scrubbing else { return }
                            model.go(toProgression: target)
                            // if the page never reports back, let go anyway
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                if !dragging { scrubbing = nil }
                            }
                        }
                    )
                    .tint(.ptAccent)
                    .accessibilityLabel("Position in book")
                    .accessibilityValue("\(Int((shownProgress * 100).rounded())) percent")
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .ptGlassCapsule()

                if model.canReadAloud {
                    PTIconButton(
                        systemImage: model.readAloud != nil ? "speaker.wave.2.fill" : "speaker.wave.2",
                        label: "Read aloud"
                    ) { model.toggleReadAloud(); model.revealChrome() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    /// Goes to a position set without a drag (an accessibility adjustment), after a short pause for further steps.
    private func settleScrub(at value: Double) {
        scrubTask?.cancel()
        scrubTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, !dragging else { return }
            model.go(toProgression: value)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled, !dragging { scrubbing = nil }
        }
    }

    /// Under the title: the chapter — unless that is only the title again — or else the author.
    private var secondLine: String? {
        let author = model.book.author.isEmpty ? nil : model.book.author
        guard let chapter = model.chapterTitle, !chapter.isEmpty,
              chapter.caseInsensitiveCompare(model.book.title) != .orderedSame
        else { return author }
        return chapter
    }

    /// The percent through — a tap swaps it for the time left at this reader's pace (when there is a pace to go on).
    @ViewBuilder
    private var progressLabel: some View {
        let percent = "\(Int((shownProgress * 100).rounded()))%"
        let available = model.timeLeftText(at: shownProgress)
        let left = showsTimeLeft ? available : nil
        let label = Text(left ?? percent)
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
            .frame(minWidth: 36, minHeight: 44, alignment: .leading)
            .ptNumberRoll(on: left ?? percent)
        // a button only when there is a time left to switch to
        if available != nil {
            Button { showsTimeLeft.toggle(); model.revealChrome() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(left ?? "\(percent) through the book")
                .accessibilityHint("Switches between percent and time left")
        } else {
            label.accessibilityLabel("\(percent) through the book")
        }
    }

    private var shownProgress: Double {
        min(max(scrubbing ?? model.book.progression ?? 0, 0), 1)
    }

    /// "Back to 45%" — after a jump, one tap returns to where the reader was.
    private func backChip(_ label: String) -> some View {
        HStack(spacing: 0) {
            Button { model.goBack(); model.revealChrome() } label: {
                Label("Back to \(label)", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.dismissBack(); model.revealChrome() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 38, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.primary)
        .ptGlassCapsule(interactive: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// "‹ 3 of 12 ›" — step through the matches of the last search without reopening it.
    private func searchStepper(index: Int, count: Int) -> some View {
        HStack(spacing: 0) {
            Button { model.stepSearchHit(-1); model.revealChrome() } label: {
                Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous match")
            Text("\(index + 1) of \(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
            Button { model.stepSearchHit(1); model.revealChrome() } label: {
                Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Next match")
            Button { model.endSearchStepping(); model.revealChrome() } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).frame(minWidth: 38, minHeight: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Done with search")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .ptGlassCapsule(interactive: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    /// The Contents sheet's tab: chapters unless there are none to show.
    private var contentsTabNow: ContentsTab {
        let available = ContentsTab.allCases.filter { contentsHas($0) }
        return available.contains(contentsTab) ? contentsTab : (available.first ?? .chapters)
    }

    private func contentsHas(_ tab: ContentsTab) -> Bool {
        switch tab {
        case .chapters: return !model.toc.isEmpty
        case .bookmarks: return !model.book.bookmarks.isEmpty
        case .highlights: return !model.book.highlights.isEmpty
        }
    }

    /// Chapters | Bookmarks | Highlights — only the ones with something in them, and only when there is a choice.
    @ViewBuilder
    private var contentsPicker: some View {
        let available = ContentsTab.allCases.filter { contentsHas($0) }
        if available.count > 1 {
            Picker("Show", selection: Binding(get: { contentsTabNow }, set: { contentsTab = $0 })) {
                ForEach(available) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var contentsSheet: some View {
        let tab = contentsTabNow
        return NavigationStack {
            Group {
                if model.toc.isEmpty, model.book.bookmarks.isEmpty, model.book.highlights.isEmpty {
                    Text("No table of contents.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                    contentsPicker
                    List {
                        if tab == .highlights {
                            Section {
                                ForEach(model.book.highlights.sorted { ($0.progression ?? 0) < ($1.progression ?? 0) }) { hl in
                                    highlightRow(hl)
                                }
                            } header: {
                                highlightsHeader
                            }
                        }
                        if tab == .bookmarks {
                            Section("Bookmarks") {
                                ForEach(model.book.bookmarks.sorted { ($0.progression ?? 0) < ($1.progression ?? 0) }) { bm in
                                    Button {
                                        showContents = false
                                        model.goToBookmark(bm)
                                    } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(bm.title).lineLimit(1)
                                                if let p = bm.progression {
                                                    Text("\(Int((p * 100).rounded()))% through")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        } icon: {
                                            Image(systemName: "bookmark.fill")
                                        }
                                        .foregroundStyle(.primary)
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) { model.removeBookmark(bm) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        if tab == .chapters {
                            Section("Chapters") {
                                OutlineRows(links: model.toc, depth: 0, current: model.currentChapterID) { link in
                                    showContents = false
                                    model.go(to: link)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    // open at the chapter the reader is in
                    .onAppear {
                        guard let current = model.currentChapterID else { return }
                        DispatchQueue.main.async { proxy.scrollTo("toc-" + current, anchor: .center) }
                    }
                    // and again when the reader comes back to the Chapters tab
                    .onChange(of: contentsTabNow) { _, now in
                        guard now == .chapters, let current = model.currentChapterID else { return }
                        DispatchQueue.main.async { proxy.scrollTo("toc-" + current, anchor: .center) }
                    }
                    }
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showContents = false }
                }
            }
            .sheet(item: $exportFile) { item in
                ShareSheet(items: [item.url])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(scheme)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func highlightRow(_ hl: Highlight) -> some View {
        Button {
            showContents = false
            model.goToHighlight(hl)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hl.text.isEmpty ? "Highlight" : hl.text)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let note = hl.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: (hl.note ?? "").isEmpty ? "highlighter" : "note.text")
                    .foregroundStyle(HighlightColor(saved: hl.color).color)
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            Button(role: .destructive) { model.removeHighlight(hl) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                // the editor is a sheet too — let this one go first
                showContents = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.editingHighlight = hl }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.ptAccent)
        }
    }

    /// "Highlights" with a share / copy menu for the whole list as Markdown.
    private var highlightsHeader: some View {
        HStack {
            Text("Highlights")
            Spacer()
            Menu {
                Button {
                    if let url = model.highlightsFile() { exportFile = ShareItem(url: url) }
                } label: {
                    Label("Share as Markdown…", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = model.highlightsMarkdown()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label("Copy as Text", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                    .font(.subheadline)
            }
            .accessibilityLabel("Export highlights")
        }
    }

    private var searchSheet: some View {
        NavigationStack {
            SearchResultsView(model: model) {
                showSearch = false
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSearch = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Who reads aloud — reachable from the read-aloud bar, so a voice can be tried mid-page.
    private var voiceSheet: some View {
        NavigationStack {
            VoiceListView(selection: $model.settings.voiceIdentifier, rate: model.settings.speechRate)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showVoices = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var settingsSheet: some View {
        NavigationStack {
            ReaderSettingsView(settings: $model.settings, adjustsType: model.adjustsType)
                .navigationTitle("Reading")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSettings = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    /// Hide the app's tab bar while the reader's own chrome is down — iOS 18 renamed
    /// the modifier but kept the meaning.
    @ViewBuilder
    func tabBarChrome(_ visible: Bool) -> some View {
        if #available(iOS 18, *) {
            toolbarVisibility(visible ? .visible : .hidden, for: .tabBar)
        } else {
            toolbar(visible ? .visible : .hidden, for: .tabBar)
        }
    }
}

/// Hosts a Readium navigator (EPUB or PDF) inside SwiftUI.
private struct NavigatorRepresentable: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private struct OutlineRows: View {
    let links: [ReadiumShared.Link]
    let depth: Int
    /// Where this level starts in the outline ("" at the top), and the position of the entry the reader is in.
    var path = ""
    var current: String?
    let onSelect: (ReadiumShared.Link) -> Void

    var body: some View {
        ForEach(Array(links.enumerated()), id: \.offset) { i, link in
            let id = path.isEmpty ? "\(i)" : "\(path).\(i)"
            let here = id == current
            Button { onSelect(link) } label: {
                HStack {
                    Text(link.title.flatMap { $0.isEmpty ? nil : $0 } ?? (depth == 0 ? "Section \(i + 1)" : "Untitled"))
                        .padding(.leading, CGFloat(depth * 16))
                        .foregroundStyle(here ? Color.ptAccent : Color.primary)
                        .fontWeight(here ? .semibold : .regular)
                    if here {
                        Spacer(minLength: 8)
                        Image(systemName: "location.fill").font(.caption).foregroundStyle(Color.ptAccent)
                    }
                }
            }
            .id("toc-" + id)
            .accessibilityAddTraits(here ? .isSelected : [])
            OutlineRows(links: link.children, depth: depth + 1, path: id, current: current, onSelect: onSelect)
        }
    }
}

private struct ReadAloudBar: View {
    @ObservedObject var readAloud: ReadAloud
    let rate: Double
    let onInteraction: () -> Void
    let onRate: () -> Void
    let onVoice: () -> Void
    let onStop: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                transportControls
                rateButton
                barButton("person.wave.2", label: "Voice", action: onVoice)
                sleepMenu
                barButton("xmark", label: "Stop reading aloud", action: onStop)
            }
            HStack(spacing: 2) {
                transportControls
                rateButton
                Menu {
                    Button("Voice", systemImage: "person.wave.2", action: onVoice)
                    Divider()
                    sleepChoices
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 40, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More read-aloud controls")
                .simultaneousGesture(TapGesture().onEnded { _ in onInteraction() })
                barButton("xmark", label: "Stop reading aloud", action: onStop)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .ptGlassCapsule()
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var transportControls: some View {
        Group {
            barButton("backward.fill", label: "Previous sentence") { readAloud.previous() }
            barButton(readAloud.isPlaying ? "pause.fill" : "play.fill", label: readAloud.isPlaying ? "Pause" : "Play", large: true) {
                readAloud.playPause()
            }
            barButton("forward.fill", label: "Next sentence") { readAloud.next() }
        }
    }

    private var rateButton: some View {
        Button(action: onRate) {
            Text(String(format: "%.3g×", rate))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .ptNumberRoll(on: rate)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speaking speed")
        .accessibilityValue(String(format: "%.3g times", rate))
    }

    private var sleepMenu: some View {
        Menu {
            sleepChoices
        } label: {
            Group {
                if let left = readAloud.sleepRemaining {
                    // ceil — "5:00 left" shows 5m until it drops under 4:00
                    Text("\(Int(left / 60) + 1)m").font(.subheadline.monospacedDigit())
                } else {
                    Image(systemName: "moon")
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(readAloud.sleepRemaining.map { "\(Int($0 / 60) + 1) minutes left" } ?? "Off")
        .simultaneousGesture(TapGesture().onEnded { _ in onInteraction() })
    }

    @ViewBuilder
    private var sleepChoices: some View {
        if let left = readAloud.estimatedRemaining {
            Text("\(ReadingPace.label(minutesLeft: left / 60)) in the book")
        }
        Button("Sleep timer off") { onInteraction(); readAloud.setSleepTimer(minutes: nil) }
        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
            Button("Sleep in \(minutes) minutes") { onInteraction(); readAloud.setSleepTimer(minutes: minutes) }
        }
    }

    private func barButton(_ symbol: String, label: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: symbol)
                .font(large ? .title2 : .body)
                .ptSymbolSwap(on: symbol)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct SearchResultsView: View {
    @ObservedObject var model: ReaderModel
    let onPick: () -> Void
    @State private var query: String
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(model: ReaderModel, onPick: @escaping () -> Void) {
        self.model = model
        self.onPick = onPick
        // reopening the sheet picks up where it was: the same query and its matches
        _query = State(initialValue: model.searchedQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this book", text: $query)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { model.search(query) }
                if model.searchInFlight { ProgressView() }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding([.horizontal, .top])

            if !model.searchResults.isEmpty {
                Text(model.searchResults.count >= 200 ? "200+ matches" : "\(model.searchResults.count) \(model.searchResults.count == 1 ? "match" : "matches")")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.top, 8)
            }
            List(Array(model.searchResults.enumerated()), id: \.offset) { i, locator in
                Button {
                    onPick()
                    model.goToSearchHit(locator)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // a PDF hit has no chapter title but does have its page
                        Text(locator.title ?? locator.locations.position.map { "Page \($0)" } ?? "Match \(i + 1)")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let highlight = locator.text.highlight, !highlight.isEmpty {
                (Text("…\((locator.text.before ?? "").trimmingCharacters(in: .whitespaces)) ")
                                + Text(highlight).bold().foregroundColor(.primary)
                                + Text(" \((locator.text.after ?? "").trimmingCharacters(in: .whitespaces))…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)
            .overlay {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if model.searchFailed {
                    Text("This book can’t be searched.")
                        .foregroundStyle(.secondary)
                } else if !model.searchInFlight, model.searchResults.isEmpty, !trimmed.isEmpty,
                          model.searchedQuery == trimmed {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
        // the keyboard is up and waiting when the sheet is
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, q in
            debounceTask?.cancel()
            // cleared: the old results go now, not after the pause
            if q.trimmingCharacters(in: .whitespaces).isEmpty { model.search(""); return }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                model.search(q)
            }
        }
    }
}

/// The sections of the Contents sheet.
enum ContentsTab: String, CaseIterable, Identifiable {
    case chapters, bookmarks, highlights
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chapters: return "Chapters"
        case .bookmarks: return "Bookmarks"
        case .highlights: return "Highlights"
        }
    }
}
