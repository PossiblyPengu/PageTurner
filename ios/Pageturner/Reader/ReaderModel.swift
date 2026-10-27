import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import WebKit

/// A footnote or endnote the reader tapped — shown in a sheet instead of jumping to it.
struct Footnote: Identifiable {
    let id = UUID()
    let text: String
    /// What it was called where it was cited: "3", "†".
    let label: String?
    let link: ReadiumShared.Link
}

@MainActor
final class ReaderModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var book: Book
    @Published private(set) var showChrome = true
    @Published var settings = ReaderSettings.load()
    @Published var toc: [ReadiumShared.Link] = []
    @Published var canReadAloud = false
    @Published var isSearchable = false
    @Published private(set) var readAloud: ReadAloud?
    @Published var notice: String?
    @Published private(set) var isCurrentLocationBookmarked = false
    /// The chapter the reader is in, for the title chip. Nil for comics and PDFs without an outline.
    @Published private(set) var chapterTitle: String?
    /// The contents entry the reader is in, to mark it and scroll to it in the Contents sheet.
    @Published private(set) var currentChapterID: String?
    @Published private(set) var searchInFlight = false
    @Published private(set) var searchResults: [Locator] = []
    /// The query the current results answer — "No matches" is only true once a search for what is typed has finished.
    @Published private(set) var searchedQuery = ""
    /// The last search could not run at all (as opposed to finding nothing).
    @Published private(set) var searchFailed = false
    /// Which match the reader is on, so the next/previous arrows know where to step from.
    @Published private(set) var searchHitIndex: Int?
    /// Whether font, spacing and margins mean anything for this book (a PDF's pages are fixed).
    @Published private(set) var adjustsType = true
    /// Where a "Back" button would return to after a jump.
    @Published private(set) var history = JumpHistory()
    @Published var footnote: Footnote?
    /// The highlight whose colour and note are being edited.
    @Published var editingHighlight: Highlight?

    private let library: LibraryStore
    private var publication: Publication?
    private var navigator: (any VisualNavigator)?
    private(set) var navigatorController: UIViewController?
    private var directionalAdapter: DirectionalNavigationAdapter?
    /// Whether the page in front has been told the bionic switch's current state.
    private var bionicApplied = false
    /// Whether it is after dark right now — kept fresh by `refreshNight`, so a theme that follows the
    /// clock changes while the book is open.
    @Published private(set) var nightNow = ReaderSettings.isNight(Date())

    /// The settings as the page shows them: the reader's choices, with the evening theme applied.
    var activeSettings: ReaderSettings { settings.resolved(night: nightNow) }

    func refreshNight() {
        let night = ReaderSettings.isNight(Date())
        guard night != nightNow else { return }
        nightNow = night
        if settings.autoNight { applySettings() }
    }
    private var inputTokens: Set<InputObservableToken> = []
    /// Every page turn used to re-encode and rewrite the whole catalogue
    /// JSON — a disk write per page. Coalesced here and flushed on close.
    private var saveTask: Task<Void, Never>?
    private var currentLocator: Locator?
    /// Where read-aloud has carried the book while the reader was away: the page is behind it until the reader is
    /// back and has caught up, so the navigator's own location is not the place to save.
    private var narrationAhead: Locator?
    /// Where and when this sitting began, for the BookMaster session push.
    private var sessionStart: (at: Date, progression: Double)?
    /// The last page turn or return to the book — a book left open on a table stops counting five minutes after it.
    private var lastActivityAt = Date()
    /// How much of the book was actually read this sitting — page turns, not jumps.
    private var reading = ReadingSpan()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Where the reader was when this app began a jump, and the location before
    /// the latest one — together they tell a jump's origin however the two
    /// callbacks (jumped / location changed) happen to be ordered.
    private var pendingOrigin: Locator?
    private var previousLocator: Locator?
    /// Set while "Back" is navigating, so returning isn't recorded as a jump.
    private var returning = false
    private var chromeHideTask: Task<Void, Never>?
    static let highlightGroup = "user-highlights"
    static let searchHitGroup = "search-hit"
    private var searchHitGeneration = 0

    init(book: Book, library: LibraryStore) {
        self.book = book
        self.library = library
    }

    func open() async {
        // the Reading tab restarts this task on every return — open once
        guard publication == nil, phase == .loading else { return }
        do {
            let publication = try await Readium.shared.open(url: library.fileURL(for: book))
            self.publication = publication
            reading = ReadingSpan(startingAt: book.progression)
            var initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
            // opened from a highlight in the hub: land on it, not where the book was left
            if let requested = OpenAt.take(for: book.id), let place = await Self.resolve(requested, in: publication) {
                initial = place
            }
            // no saved place but a progression (a jump to where BookMaster has
            // the book, or a restored backup): find that point in the book
            if initial == nil, let progression = book.progression, progression > 0.001 {
                initial = await publication.locate(progression: min(progression, 0.999))
            }

            // comics (cbz) are opened by the EPUB navigator too — the CBZ one is deprecated
            if publication.conforms(to: .epub) || publication.conforms(to: .divina) {
                var config = EPUBNavigatorViewController.Configuration(
                    preferences: activeSettings.epubPreferences
                )
                // custom action on the selection menu — handled by
                // ReaderContainerViewController in the responder chain
                var actions = EditingAction.defaultActions + [
                    EditingAction(
                        title: "Highlight",
                        action: #selector(ReaderContainerViewController.highlightSelection)
                    ),
                    EditingAction(
                        title: "Save Word",
                        action: #selector(ReaderContainerViewController.saveWordSelection)
                    ),
                ]
                if BookMaster.shared.isLinked {
                    actions.append(EditingAction(
                        title: "Quote",
                        action: #selector(ReaderContainerViewController.quoteSelection)
                    ))
                }
                config.editingActions = actions
                // how read-aloud lights the word and the line it is on
                config.decorationTemplates[.spokenWord] = .spokenWord()
                config.decorationTemplates[.spokenLine] = .spokenLine()
                let nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initial,
                    config: config
                )
                nav.delegate = self
                install(navigator: nav, controller: nav)
            } else if publication.conforms(to: .pdf) {
                var actions = EditingAction.defaultActions
                actions.append(EditingAction(title: "Save Word", action: #selector(ReaderContainerViewController.saveWordSelection)))
                if BookMaster.shared.isLinked {
                    actions.append(EditingAction(title: "Quote", action: #selector(ReaderContainerViewController.quoteSelection)))
                }
                let nav = try PDFNavigatorViewController(
                    publication: publication,
                    initialLocation: initial,
                    config: .init(preferences: activeSettings.pdfPreferences, editingActions: actions),
                    delegate: self
                )
                adjustsType = false
                install(navigator: nav, controller: nav)
            } else {
                phase = .failed("This book's format isn't supported yet.")
                return
            }

            book.lastOpenedAt = Date()
            library.saveReading(book)
            canReadAloud = ReadAloud.canSpeak(publication)
            isSearchable = publication.isSearchable
            toc = (try? await publication.tableOfContents().get()) ?? []
            // a comic's reading order is every page — not a contents worth listing, and a
            // one-item order (a PDF without an outline) is no contents either. Untitled
            // entries stay untitled here: the list labels them "Section N" for display only.
            if toc.isEmpty, !publication.conforms(to: .divina), publication.readingOrder.count > 1 {
                toc = publication.readingOrder
            }
            if publication.conforms(to: .divina) { adjustsType = false }
            learnPageCount(publication: publication)
            phase = .ready
            autoHideChrome()
            #if DEBUG
            Task { await debugTurn() }
            #endif
        } catch {
            // a task cancelled by a tab switch is not a failed book — the next appearance retries
            if Task.isCancelled, publication == nil { return }
            Log.error("reader", "open failed for \(book.title): \(error.localizedDescription)")
            // the technical detail is in the log; the reader gets a sentence
            phase = .failed("This book couldn’t be opened. The file may be damaged or missing.")
        }
    }

    /// Open again after a failure.
    func retry() {
        publication = nil
        phase = .loading
        Task { await open() }
    }

    /// Edge taps turn pages (DirectionalNavigationAdapter); anything left over
    /// toggles the chrome — same setup as the Readium Test App.
    private func install(navigator: any VisualNavigator, controller: UIViewController) {
        self.navigator = navigator

        // container puts our selection-action selectors in the responder chain
        let container = ReaderContainerViewController(contentController: controller)
        container.onHighlightSelection = { [weak self] in self?.highlightSelection() }
        container.onQuoteSelection = { [weak self] in self?.quoteSelection() }
        container.onSaveWordSelection = { [weak self] in self?.saveWordSelection() }
        navigatorController = container

        // which side of the page was tapped, for the way a page turn leaves (the adapter's own callback has no side)
        navigator.addObserver(.tap { [weak self] event in
            if let width = self?.navigatorController?.view.bounds.width, width > 0 {
                self?.tapOnLeft = event.location.x < width / 2
            }
            return false
        }).store(in: &inputTokens)

        navigator.addObserver(.click { [weak self] event in
            if let width = self?.navigatorController?.view.bounds.width, width > 0 {
                self?.tapOnLeft = event.location.x < width / 2
            }
            return false
        }).store(in: &inputTokens)
        navigator.addObserver(.key { [weak self] event in
            switch event.key {
            case .arrowLeft, .arrowUp: self?.tapOnLeft = true
            case .arrowRight, .arrowDown, .space: self?.tapOnLeft = false
            default: break
            }
            return false
        }).store(in: &inputTokens)

        let adapter = DirectionalNavigationAdapter(
            animatedTransition: settings.pageTurn == .slide,
            onNavigation: { [weak self] in self?.pageIsTurning() })
        adapter.pointerPolicy.horizontalEdgeThresholdPercent = settings.tapZone.percent
        adapter.pointerPolicy.minimumHorizontalEdgeSize = settings.tapZone.minimumEdge
        adapter.bind(to: navigator)
        directionalAdapter = adapter

        navigator.addObserver(.activate { [weak self] _ in
            self?.toggleChrome()
            return true
        }).store(in: &inputTokens)

        applyHighlights()
        (navigator as? DecorableNavigator)?.observeDecorationInteractions(inGroup: Self.highlightGroup) { [weak self] event in
            self?.highlightActivated(event.decoration.id)
        }

        // the leaf that follows the finger — only when the style asks for it
        // and the book is paged (a scrolling page has nothing to peel)
        container.canCurl = { [weak self] in
            guard let self else { return false }
            // never while text is selected: a drag then belongs to the selection handles
            // Reduce Motion turns pages with a fade (the tap path), so a drag has no peel to follow either
            return self.settings.pageTurn == .curl && !UIAccessibility.isReduceMotionEnabled
                && !(self.navigator?.presentation.scroll ?? true)
                && (self.navigator as? SelectableNavigator)?.currentSelection == nil
        }
        container.onCurlStep = { [weak self] forward in
            await self?.curlStep(forward) ?? false
        }
        container.onCurlCommit = { [weak self] in self?.curlCommitted() }
        container.onCurlCancel = { [weak self] in await self?.curlCancelled() }
        container.rightToLeft = navigator.presentation.readingProgression == .rtl
    }

    private var tapOnLeft = false

    /// Called just before the adapter changes the page: when the reader has chosen another turn than
    /// Readium's slide, the page as it is now leaves over what comes next.
    private func pageIsTurning(frozenAt: Double? = nil) {
        defer { tapOnLeft = false }
        if settings.turnHaptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        if settings.turnSound { PageTurnSound.shared.play() }
        guard settings.pageTurn != .slide, !(navigator?.presentation.scroll ?? false),
              let container = navigatorController as? ReaderContainerViewController
        else { return }
        // nothing to turn to — the first page tapped backward, the last tapped forward: no turn to show
        if let navigator {
            let forward = navigator.presentation.readingProgression == .rtl ? tapOnLeft : !tapOnLeft
            let place = navigator.currentLocation?.locations.totalProgression ?? 0.5
            if forward ? place >= 0.9999 : place <= 0.0001 { return }
        }
        // less motion asked for: a cross-fade, never a swing
        let style: PageTurnStyle = UIAccessibility.isReduceMotionEnabled ? .fade : settings.pageTurn
        if style == .curl {
            container.beginCurl(towardLeft: !tapOnLeft, frozenAt: frozenAt)
            return
        }
        container.beginTurn(towardLeft: !tapOnLeft, style: style, frozenAt: frozenAt)
    }

    // MARK: - Page curl

    /// While a finger-tracked curl holds the navigator: the page underneath
    /// has already been moved to wherever the leaf lands, so position saves,
    /// jump history and BookMaster sync must wait for it to settle — or be
    /// put back on cancel.
    private(set) var curling = false
    /// Where the reader was when the leaf was caught — the place to return to
    /// if the peel is released. `curlMoved` tracks whether the navigator
    /// actually moved, so a cancelled turn that never did isn't restored onto
    /// itself (a `go` to the current page can reload the resource visibly).
    private var curlBefore: Locator?
    private var curlMoved = false

    /// Silently steps the navigator one page with all side-effects held.
    /// False = no page that way (the gesture aborts).
    private func curlStep(_ forward: Bool) async -> Bool {
        guard let navigator else { return false }
        if curlBefore == nil { curlBefore = navigator.currentLocation; curlMoved = false }
        curling = true
        let moved = forward
            ? await navigator.goForward(options: NavigatorGoOptions(animated: false))
            : await navigator.goBackward(options: NavigatorGoOptions(animated: false))
        curlMoved = curlMoved || moved
        return moved
    }

    /// The leaf landed: release the hold and let the arrived page count.
    private func curlCommitted() {
        if settings.turnHaptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        if settings.turnSound { PageTurnSound.shared.play() }
        curling = false
        curlBefore = nil
        curlMoved = false
        if let navigator, let locator = navigator.currentLocation {
            self.navigator(navigator, locationDidChange: locator)
        }
    }

    /// The leaf sprang back: silently restore the page it was lifted from.
    private func curlCancelled() async {
        guard curling, let navigator else { curlBefore = nil; curlMoved = false; return }
        if curlMoved, let before = curlBefore {
            _ = await navigator.go(to: before, options: NavigatorGoOptions(animated: false))
        }
        curling = false
        curlBefore = nil
        curlMoved = false
    }

    #if DEBUG
    /// CI simulator run: turn the page once and hold the turn part way for the photograph (-PTDebugTurn flip).
    func debugTurn() async {
        guard let raw = UserDefaults.standard.string(forKey: "PTDebugTurn"), let style = PageTurnStyle(rawValue: raw),
              let navigator else { return }
        try? await Task.sleep(nanoseconds: 6_000_000_000)   // until the page has painted, or the turn is of a spinner
        settings.pageTurn = style
        // -PTDebugTurnBack YES: the turn back, a tap on the left edge — the page peels away over the one before it
        let back = UserDefaults.standard.bool(forKey: "PTDebugTurnBack")
        tapOnLeft = back
        pageIsTurning(frozenAt: 0.5)
        _ = back
            ? await navigator.goBackward(options: NavigatorGoOptions(animated: false))
            : await navigator.goForward(options: NavigatorGoOptions(animated: false))
    }
    #endif

    func toggleChrome() {
        if showChrome {
            hideChrome()
        } else {
            revealChrome()
        }
    }

    func revealChrome() {
        if !showChrome { withAnimation { showChrome = true } }
        autoHideChrome()
    }

    func holdChrome() {
        chromeHideTask?.cancel()
        if !showChrome { withAnimation { showChrome = true } }
    }

    private func hideChrome() {
        chromeHideTask?.cancel()
        withAnimation { showChrome = false }
    }

    private func autoHideChrome() {
        chromeHideTask?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        #if DEBUG
        // CI simulator run: keep the controls up for the screenshots (Debug/DebugScenario.swift)
        if UserDefaults.standard.bool(forKey: "PTDebugKeepChrome") { return }
        #endif
        chromeHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.showChrome else { return }
            self.hideChrome()
        }
    }

    func go(to link: ReadiumShared.Link) {
        guard let navigator else { return }
        navigate { await navigator.go(to: link) }
    }

    /// A search hit: jump there and mark the match for a few seconds, so it can be found on a full page.
    func goToSearchHit(_ locator: Locator) {
        searchHitIndex = searchResults.firstIndex(of: locator)
        go(to: locator)
        guard let decorable = navigator as? DecorableNavigator else { return }
        searchHitGeneration += 1
        let generation = searchHitGeneration
        decorable.apply(
            decorations: [Decoration(id: "search-hit", locator: locator.anchorable, style: .highlight(tint: .systemYellow))],
            in: Self.searchHitGroup
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, generation == self.searchHitGeneration else { return }
            (self.navigator as? DecorableNavigator)?.apply(decorations: [], in: Self.searchHitGroup)
        }
    }

    /// The next (+1) or previous (-1) match of the last search; wraps around.
    func stepSearchHit(_ delta: Int) {
        guard let i = searchHitIndex, !searchResults.isEmpty else { return }
        let count = searchResults.count
        goToSearchHit(searchResults[((i + delta) % count + count) % count])
    }

    /// Put the match arrows away.
    func endSearchStepping() { searchHitIndex = nil }

    func go(to locator: Locator) {
        guard let navigator else { return }
        // a locator made from the book's text (a search hit) can carry a cssSelector the page
        // can't parse — strip it so the text anchor resolves (see Locator.anchorable)
        navigate { await navigator.go(to: locator.anchorable, options: NavigatorGoOptions(animated: true)) }
    }

    /// The scrubber: jump to a point `progression` (0…1) through the book.
    func go(toProgression progression: Double) {
        guard let publication, let navigator else { return }
        navigate {
            guard let target = await publication.locate(progression: min(max(progression, 0), 0.999)) else { return false }
            return await navigator.go(to: target, options: NavigatorGoOptions(animated: false))
        }
    }

    /// Learn the file's real page count once, so pushes to BookMaster can carry
    /// `total_pages` and a page-less ebook's percent stops being its only
    /// position. PDFs and comics page honestly (one locator per page); an EPUB
    /// answers only when it ships a page list — a reflowed position list is
    /// pseudo-pages, not pages, and stays unpushed.
    private func learnPageCount(publication: Publication) {
        guard book.pages == nil else { return }
        Task {
            let count: Int?
            if !publication.pageList.isEmpty {
                count = publication.pageList.count
            } else if ["pdf", "cbz"].contains(book.ext) {
                count = try? await publication.positions().get().count
            } else {
                count = nil
            }
            guard let count, count > 0, book.pages == nil else { return }
            book.pages = count
            library.saveReading(book)
        }
    }

    /// A jump the reader asked for: where they are now is the way back. (The
    /// navigator reports the jump itself from inside `go`, so the origin only
    /// needs to stand until it returns.)
    private func navigate(_ jump: @escaping () async -> Bool) {
        pendingOrigin = currentLocator
        Task {
            _ = await jump()
            pendingOrigin = nil
        }
    }

    /// A place asked for from outside (the highlights hub, the switch between a PDF and its text version), found in
    /// the open book.
    private static func resolve(_ place: OpenAt.Place, in publication: Publication) async -> Locator? {
        switch place {
        case let .locator(json):
            return try? Locator(jsonString: json)
        case let .position(n):
            guard let positions = try? await publication.positions().get(), !positions.isEmpty else { return nil }
            return positions[min(max(n - 1, 0), positions.count - 1)]
        case let .chapter(index, progression):
            guard publication.readingOrder.indices.contains(index),
                  let start = await publication.locate(publication.readingOrder[index])
            else { return nil }
            return start.copy(locations: { $0.progression = min(max(progression, 0), 1) })
        }
    }

    /// Where this book is now, as the other version of it would open it: a PDF's page (0-based), or a text
    /// version's chapter and how far into it.
    var versionPlace: (page: Int?, chapter: (index: Int, progression: Double)?) {
        guard let locator = navigator?.currentLocation ?? book.locatorJSON.flatMap({ try? Locator(jsonString: $0) }) else {
            return (nil, nil)
        }
        if book.ext == "pdf" {
            return (locator.locations.position.map { $0 - 1 }, nil)
        }
        let href = locator.href.string
        guard let index = publication?.readingOrder.firstIndex(where: { $0.url().isEquivalentTo(locator.href) })
                ?? Self.chapterNumber(in: href).map({ $0 - 1 })
        else { return (nil, nil) }
        return (nil, (index, locator.locations.progression ?? 0))
    }

    /// A PDF's saved page (0-based), for opening its text version there from outside the reader.
    static func savedPDFPage(of book: Book) -> Int? {
        book.locatorJSON.flatMap { try? Locator(jsonString: $0) }?.locations.position.map { $0 - 1 }
    }

    /// A text version's saved chapter (0-based, in reading order) and how far into it.
    static func savedChapter(of book: Book) -> (index: Int, progression: Double)? {
        guard let locator = book.locatorJSON.flatMap({ try? Locator(jsonString: $0) }),
              let number = chapterNumber(in: locator.href.string)
        else { return nil }
        return (number - 1, locator.locations.progression ?? 0)
    }

    /// "OEBPS/ch012.xhtml" → 12: the text importer's chapter files.
    private static func chapterNumber(in href: String) -> Int? {
        guard let range = href.range(of: #"ch([0-9]+)\.xhtml"#, options: .regularExpression) else { return nil }
        return Int(href[range].dropFirst(2).dropLast(6))
    }

    // MARK: - What was read

    /// The navigator says a jump was made. One the reader asked for (or a link they followed) is not
    /// reading; read-aloud following the narration is.
    fileprivate func noteJump() {
        guard pendingOrigin != nil || readAloud?.isFollowingNarration != true else { return }
        reading.jumped()
    }

    // MARK: - Back

    /// A jump was made (the contents, a search hit, a link in the page, the
    /// scrubber): remember where the reader was, so Back can return.
    fileprivate func recordJump(to target: Locator) {
        guard !returning else { return }
        // Read aloud follows the narration with jumps of its own; only a jump the
        // reader asked for counts then
        let own = pendingOrigin
        let reading = readAloud?.isFollowingNarration == true
        guard let origin = own ?? (reading ? nil : origin(ofJumpTo: target)),
              let from = spot(origin), let landed = spot(target)
        else { return }
        history.record(origin: from, landed: landed)
    }

    /// The origin of a jump the navigator made on its own (a link in the page):
    /// the current location — or, when it has already moved on to the target
    /// by the time this is told, the one before.
    private func origin(ofJumpTo target: Locator) -> Locator? {
        guard let current = currentLocator else { return nil }
        let moved = current.href.isEquivalentTo(target.href)
            && abs((current.locations.progression ?? 0) - (target.locations.progression ?? 0)) < 0.02
        return moved ? (previousLocator ?? current) : current
    }

    private func spot(_ locator: Locator) -> JumpHistory.Spot? {
        guard let json = try? locator.jsonString() else { return nil }
        return JumpHistory.Spot(
            locatorJSON: json, href: locator.href.string,
            progression: locator.locations.totalProgression ?? 0)
    }

    func goBack() {
        guard let spot = history.goBack(),
              let locator = try? Locator(jsonString: spot.locatorJSON),
              let navigator
        else { return }
        returning = true
        Task {
            _ = await navigator.go(to: locator, options: NavigatorGoOptions(animated: true))
            returning = false
        }
    }

    func dismissBack() { history.clear() }

    /// "Back to 45%" — what the chip says.
    var backLabel: String? {
        history.back.map { "\(Int((min(max($0.progression, 0), 1) * 100).rounded()))%" }
    }

    // MARK: - Bookmarks

    private func bookmark(matching locator: Locator) -> Bookmark? {
        book.bookmarks.first { bm in
            guard let bl = try? Locator(jsonString: bm.locatorJSON) else { return false }
            return sameSpot(bl, locator)
        }
    }

    /// Full Locator equality never holds across a font change or in scroll mode, so a
    /// bookmark is "here" when it is in the same resource at the same page or nearly the same point.
    private func sameSpot(_ a: Locator, _ b: Locator) -> Bool {
        guard a.href.isEquivalentTo(b.href) else { return false }
        if let pa = a.locations.position, let pb = b.locations.position { return pa == pb }
        if let ta = a.locations.totalProgression, let tb = b.locations.totalProgression {
            return abs(ta - tb) < 0.003
        }
        return a == b
    }

    func toggleBookmark() {
        guard let locator = currentLocator,
              let json = try? locator.jsonString()
        else { return }
        if bookmark(matching: locator) != nil {
            book.bookmarks.removeAll { bm in
                guard let bl = try? Locator(jsonString: bm.locatorJSON) else { return false }
                return sameSpot(bl, locator)
            }
        } else {
            let title = locator.title
                ?? chapterTitle(for: locator)
                ?? "Bookmark \(book.bookmarks.count + 1)"
            book.bookmarks.append(Bookmark(
                title: title,
                locatorJSON: json,
                progression: locator.locations.totalProgression
            ))
        }
        isCurrentLocationBookmarked = bookmark(matching: locator) != nil
        flushSave()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        book.bookmarks.removeAll { $0.id == bookmark.id }
        // the header's icon follows the page's bookmark — which may just have been this one
        isCurrentLocationBookmarked = currentLocator.map { self.bookmark(matching: $0) != nil } ?? false
        flushSave()
    }

    func goToBookmark(_ bookmark: Bookmark) {
        guard let locator = try? Locator(jsonString: bookmark.locatorJSON) else { return }
        go(to: locator)
    }

    /// The TOC is an outline — a bookmark's chapter is the deepest entry whose
    /// file matches the locator's href (fragments ignored, last match wins
    /// because the spine is ordered).
    func chapterTitle(for locator: Locator) -> String? { chapterLink(for: locator)?.title }

    func chapterLink(for locator: Locator) -> ReadiumShared.Link? { chapterEntry(for: locator)?.link }

    /// The contents entry for a place, with its position in the outline ("2.0.1") — two entries can share a file,
    /// so the position is what says which one the reader is in.
    func chapterEntry(for locator: Locator) -> (link: ReadiumShared.Link, id: String)? {
        var flat: [(link: ReadiumShared.Link, id: String)] = []
        func flatten(_ links: [ReadiumShared.Link], _ path: String) {
            for (i, link) in links.enumerated() {
                let id = path.isEmpty ? "\(i)" : "\(path).\(i)"
                flat.append((link, id))
                flatten(link.children, id)
            }
        }
        flatten(toc, "")
        let base = locator.href.string.split(separator: "#").first.map(String.init) ?? locator.href.string
        // a file with several entries in the contents (one per section, `file.xhtml#section`): without
        // knowing where the sections lie, the entry for the whole file — else the first — is the safe
        // answer; the last would name the end of the chapter on its first page
        var wholeFile: (link: ReadiumShared.Link, id: String)?
        var first: (link: ReadiumShared.Link, id: String)?
        for entry in flat {
            let url = entry.link.url().string
            let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard (parts.first.map(String.init) ?? url) == base else { continue }
            if first == nil { first = entry }
            if parts.count < 2 || parts[1].isEmpty, wholeFile == nil { wholeFile = entry }
        }
        return wholeFile ?? first
    }

    /// "~1 h 12 min left" at `progress`, from how fast this reader has read — nil without enough history.
    func timeLeftText(at progress: Double) -> String? {
        guard let pace = ReadingPace.minutesPerBook(ReadingLog.shared.sessions, bookID: book.id),
              let left = ReadingPace.minutesLeft(progress: progress, minutesPerBook: pace)
        else { return nil }
        return ReadingPace.label(minutesLeft: left)
    }

    // MARK: - Search

    func search(_ query: String) {
        searchTask?.cancel()
        // one search at a time owns the spinner and the list: an older one finishing late must not touch either
        searchGeneration += 1
        let generation = searchGeneration
        let q = query.trimmingCharacters(in: .whitespaces)
        searchFailed = false
        if q != searchedQuery { searchHitIndex = nil }
        guard let publication, !q.isEmpty else {
            searchResults = []
            searchedQuery = ""
            searchInFlight = false
            return
        }
        searchInFlight = true
        searchTask = Task { @MainActor in
            defer { if generation == searchGeneration { searchInFlight = false } }
            switch await publication.search(query: q) {
            case let .success(iterator):
                var found: [Locator] = []
                // LocatorCollections stream in pages; cap so a common word in a
                // huge book doesn't produce an unbounded list.
                while let page = try? await iterator.next().get() {
                    if Task.isCancelled { return }
                    found.append(contentsOf: page.locators)
                    if found.count >= 200 { break }
                }
                guard generation == searchGeneration, !Task.isCancelled else { return }
                searchResults = found
                searchedQuery = q
            case .failure:
                guard generation == searchGeneration, !Task.isCancelled else { return }
                searchResults = []
                searchFailed = true
            }
        }
    }

    func applySettings() {
        // whichever way the voice was changed (the Reading sheet, the read-aloud bar, a voice that failed),
        // the speed has to be one the new voice can do
        let fitted = settings.fittedSpeechRate
        if fitted != settings.speechRate { settings.speechRate = fitted }
        settings.save()
        (navigator as? EPUBNavigatorViewController)?
            .submitPreferences(activeSettings.epubPreferences)
        (navigator as? PDFNavigatorViewController)?
            .submitPreferences(activeSettings.pdfPreferences)
        if settings.bionic != bionicApplied {
            bionicApplied = settings.bionic
            let command = BionicReading.command(on: settings.bionic)
            Task { _ = await (navigator as? EPUBNavigatorViewController)?.evaluateJavaScript(command) }
        }
        directionalAdapter?.pointerPolicy.horizontalEdgeThresholdPercent = settings.tapZone.percent
        directionalAdapter?.pointerPolicy.minimumHorizontalEdgeSize = settings.tapZone.minimumEdge
        directionalAdapter?.animatedTransition = settings.pageTurn == .slide
        readAloud?.setRate(settings.speechRate)
        readAloud?.setVoice(settings.voiceIdentifier)
        readAloud?.setHighlights(settings.highlights)
    }

    // MARK: - Highlights

    /// Send the selected passage to BookMaster as a quote on this book.
    private func quoteSelection() {
        guard let selectable = navigator as? SelectableNavigator,
              let selection = selectable.currentSelection,
              let text = selection.locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        let ref = book.bookMasterRef
        let progression = selection.locator.locations.totalProgression
        selectable.clearSelection()
        Task {
            let ok = await BookMaster.shared.postQuote(ref: ref, content: text, percent: progression)
            notice = ok.message
        }
    }

    /// "Save Word" in the selection menu — the word and the line around it, kept with the book.
    private func saveWordSelection() {
        guard let selectable = navigator as? SelectableNavigator,
              let selection = selectable.currentSelection
        else { return }
        let text = selection.locator.text
        selectable.clearSelection()
        guard let word = SavedWord.clean(text.highlight ?? "") else {
            notice = "Select a word or a short phrase to save"
            return
        }
        if book.words.contains(where: { $0.word.localizedCaseInsensitiveCompare(word) == .orderedSame }) {
            notice = "“\(word)” is already saved"
            return
        }
        book.words.append(SavedWord(
            word: word,
            context: SavedWord.context(before: text.before, word: word, after: text.after),
            chapter: chapterTitle(for: selection.locator)
        ))
        flushSave()
        notice = "Saved “\(word)”"
    }

    /// "Highlight" in the selection menu — stores the locator, notes where in the
    /// book it was, and repaints.
    private func highlightSelection() {
        guard let selectable = navigator as? SelectableNavigator,
              let selection = selectable.currentSelection,
              let json = try? selection.locator.jsonString()
        else { return }
        let made = Highlight(
            locatorJSON: json,
            text: selection.locator.text.highlight ?? "",
            chapter: chapterTitle(for: selection.locator),
            progression: selection.locator.locations.totalProgression
        )
        book.highlights.append(made)
        applyHighlights()
        selectable.clearSelection()
        flushSave()
        autoQuote(made)
    }

    /// With "Send new highlights as quotes" on, a new highlight goes to BookMaster as well — once. A passage
    /// that could not be sent stays unmarked, so it is not mistaken for sent.
    private func autoQuote(_ highlight: Highlight) {
        let text = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppPrefs.quotesAutoSend, BookMaster.shared.isLinked, !text.isEmpty else { return }
        let ref = book.bookMasterRef
        Task {
            let result = await BookMaster.shared.postQuote(ref: ref, content: text, percent: highlight.progression)
            if result != .failed { markQuoted(highlight.id) }
        }
    }

    private func markQuoted(_ id: UUID) {
        guard let i = book.highlights.firstIndex(where: { $0.id == id }) else { return }
        book.highlights[i].quoted = true
        flushSave()
    }

    func removeHighlight(_ highlight: Highlight) {
        book.highlights.removeAll { $0.id == highlight.id }
        if editingHighlight?.id == highlight.id { editingHighlight = nil }
        applyHighlights()
        flushSave()
    }

    func goToHighlight(_ highlight: Highlight) {
        guard let locator = try? Locator(jsonString: highlight.locatorJSON) else { return }
        go(to: locator)
    }

    /// A tap on a highlight in the page opens its editor.
    private func highlightActivated(_ decorationID: String) {
        let prefix = "user-highlight-"
        guard decorationID.hasPrefix(prefix),
              let id = UUID(uuidString: String(decorationID.dropFirst(prefix.count))),
              let highlight = book.highlights.first(where: { $0.id == id })
        else { return }
        editingHighlight = highlight
    }

    /// Save a highlight's colour and note from the editor.
    func updateHighlight(_ id: UUID, color: HighlightColor, note: String) {
        guard let i = book.highlights.firstIndex(where: { $0.id == id }) else { return }
        book.highlights[i].color = color == .standard ? nil : color.rawValue
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        book.highlights[i].note = trimmed.isEmpty ? nil : trimmed
        applyHighlights()
        flushSave()
    }

    /// Send a highlight to BookMaster as a quote.
    /// Returns the result's message, for the editor sheet to show inline (an alert can't present over a sheet).
    func quoteHighlight(_ highlight: Highlight) async -> BookMaster.QuoteDelivery? {
        let text = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let result = await BookMaster.shared.postQuote(ref: book.bookMasterRef, content: text, percent: highlight.progression)
        if result != .failed { markQuoted(highlight.id) }
        return result
    }

    /// The book's highlights and notes as Markdown.
    func highlightsMarkdown() -> String {
        HighlightExport.markdown(title: book.title, author: book.author, highlights: book.highlights)
    }

    /// The Markdown written to a temporary file, for the share sheet.
    func highlightsFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(HighlightExport.fileName(for: book.title))
        do {
            try highlightsMarkdown().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Re-applies every saved highlight to the document (the decorations group
    /// is replaced wholesale — same pattern as the read-aloud highlight).
    private func applyHighlights() {
        guard let decorable = navigator as? DecorableNavigator else { return }
        let decorations: [Decoration] = book.highlights.compactMap { h in
            guard let locator = try? Locator(jsonString: h.locatorJSON) else { return nil }
            return Decoration(
                id: "user-highlight-\(h.id.uuidString)",
                locator: locator,
                style: .highlight(tint: HighlightColor(saved: h.color).uiColor)
            )
        }
        decorable.apply(decorations: decorations, in: Self.highlightGroup)
    }

    // MARK: - Read aloud

    func toggleReadAloud() {
        if let readAloud {
            readAloud.playPause()
        } else {
            startReadAloud()
        }
    }

    private func startReadAloud() {
        // one voice: a book still being read aloud with its reader left gives way
        ReadAloudHost.shared.show(self)
        guard let publication, let navigator,
              let readAloud = ReadAloud(
                  publication: publication,
                  navigator: navigator,
                  settings: settings,
                  displayTitle: book.title,
                  displayAuthor: book.author
              )
        else { return }
        readAloud.onError = { [weak self] message in self?.notice = message }
        // a session that ends itself (sleep timer, repeated failures) must not leave a dead one here
        readAloud.onStopped = { [weak self, weak readAloud] in
            guard let self, let readAloud, self.readAloud === readAloud else { return }
            self.readAloud = nil
            ReadAloudHost.shared.narrationEnded(self)
        }
        readAloud.onNarrated = { [weak self] locator in self?.narrated(to: locator) }
        readAloud.onVoiceFallback = { [weak self] in
            guard let self else { return }
            settings.voiceIdentifier = nil
            settings.save()
            notice = "That voice can't play — switched to the automatic voice."
            Log.error("readaloud", "chosen voice failed — fell back to automatic")
        }
        self.readAloud = readAloud
        let voice = settings.voiceIdentifier ?? "auto"
        Log.event("readaloud", "started — voice \(voice), rate \(settings.speechRate)")
        readAloud.start()
    }

    func stopReadAloud() {
        readAloud?.stop()
        readAloud = nil
    }

    // MARK: - Read aloud with the reader away (`ReadAloudHost`)

    /// The reader is in front: the voice marks and follows the page again, catching it up first.
    func readerShown() { readAloud?.setOnScreen(true) }

    /// The reader was left with the voice still going: nothing is chased or painted until it is back.
    func readerHidden() { readAloud?.setOnScreen(false) }

    /// The narration of a book whose reader was away has ended: its place and its sitting are written down now.
    func readerLetGo() {
        saveTask?.cancel()
        saveTask = nil
        library.saveReading(book)
        endSession()
    }

    /// Read-aloud carried on with the reader away: where the voice is, is where the reader is — saved, and told to
    /// BookMaster as a page turn would be. The page catches up when the reader is back.
    func narrated(to locator: Locator) {
        currentLocator = locator
        narrationAhead = locator
        lastActivityAt = Date()
        book.locatorJSON = try? locator.jsonString()
        if let progression = locator.locations.totalProgression { book.progression = progression }
        let entry = chapterEntry(for: locator)
        chapterTitle = entry?.link.title
        currentChapterID = entry?.id
        scheduleSave()
        beginSession()
        reading.moved(to: locator.locations.totalProgression)
        pushProgress()
        #if DEBUG
        NSLog("PTNarrated %@ %.4f", entry?.link.title ?? "?", locator.locations.totalProgression ?? -1)
        #endif
    }

    func cycleRate() {
        let neural = settings.voiceIdentifier.map { NeuralVoice.key(fromID: $0) != nil } ?? false
        let steps = SpeechRateMap.cycle(neural: neural)
        settings.speechRate = steps.first { $0 > settings.speechRate + 0.001 } ?? steps[0]
    }

    func goToFootnote(_ note: Footnote) {
        footnote = nil
        go(to: note.link)
    }

    /// Persist the position soon-ish rather than instantly, and immediately
    /// when the reader is going away (called from ReaderView.onDisappear).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            library.saveReading(book)
        }
    }

    /// Write the place to disk now. Called when the reader or the app is
    /// going away — also snapshots the navigator's own location, so a turn
    /// whose callback never landed isn't the page that is lost.
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        if !curling, narrationAhead == nil, let locator = navigator?.currentLocation {
            book.locatorJSON = try? locator.jsonString()
            book.progression = locator.locations.totalProgression
        }
        library.saveReading(book)
    }

    /// Locking the screen can leave the page's webview holding a stale
    /// compositing surface — the app wakes fine but the page stays blank
    /// until something forces the remote layer to re-present. A killed web
    /// process is already healed by the navigator itself; this covers the
    /// surviving-but-stale case. Harmless when nothing went stale.
    func refreshAwake() {
        guard let view = navigatorController?.view else { return }
        Self.repaintWebViews(in: view)
    }

    /// Ask every webview under `view` to re-commit its remote layer: the same
    /// offset again (a commit round-trip), a display pass, and a half-point
    /// geometry nudge. All invisible — the frame is restored within the tick.
    private static func repaintWebViews(in view: UIView) {
        if let webView = view as? WKWebView {
            webView.scrollView.setContentOffset(webView.scrollView.contentOffset, animated: false)
            webView.setNeedsDisplay()
            let frame = webView.frame
            webView.frame.size.width += 0.5
            webView.frame = frame
        }
        view.setNeedsLayout()
        view.subviews.forEach(repaintWebViews)
    }

    /// A new sitting begins now, from wherever the book is open.
    func beginSession() {
        if sessionStart == nil, let p = book.progression {
            sessionStart = (Date(), p)
            lastActivityAt = Date()
            reading.restart(at: p)
        }
    }

    /// Tell BookMaster how far this sitting got — called when the reader is
    /// left or the app goes to the background, not on every save. The pages
    /// counted are the ones turned to, not the distance between where the
    /// sitting began and ended: jumping from 10% to 50% and closing the book
    /// is not 40% read. A peek that read under half a percent is not a session.
    func endSession() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        // a book removed while it was open: no sitting to log, no place to tell BookMaster
        guard library.books.contains(where: { $0.id == book.id }) else { return }
        let end = book.progression ?? start.progression
        let span = min(reading.span, 1)
        let reported = reading.reportable(end)
        reading.restart(at: nil)
        let endedAt = max(min(Date(), lastActivityAt.addingTimeInterval(300)), start.at)
        let minutes = endedAt.timeIntervalSince(start.at) / 60
        let moved = span * 100 >= 0.5
        // the local log keeps any real sitting — time spent, even where it hardly moved the page
        if moved || minutes >= 2 {
            ReadingLog.shared.record(book: book, minutes: minutes, from: max(end - span, 0), to: end, audio: false)
        }
        let ref = book.bookMasterRef
        Task {
            // wherever the book was left, however it got there
            await BookMaster.shared.syncProgress(
                bookKey: book.id.uuidString, ref: ref, percent: reported, isAudio: false, force: true,
                pinned: { [weak self] id in self?.pin(id) })
        }
        // its own task: both are written to the queue before they are sent, but the sitting must not wait
        // on the position's round trip — a phone locked on a slow link is suspended in the middle of it
        guard moved else { return }
        Task {
            await BookMaster.shared.syncSession(
                ref: ref, percentStart: max(reported - span, 0), percentEnd: reported,
                minutes: minutes, at: Date())
        }
    }

    private func pin(_ id: String) {
        guard book.bookmasterId != id else { return }
        book.bookmasterId = id
        library.updateBookMaster(book.id) { $0.bookmasterId = id }
    }
}

// MARK: - Navigator delegates

extension ReaderModel: EPUBNavigatorDelegate, PDFNavigatorDelegate {
    /// Every chapter's web view gets the bionic-reading script, started on or off as the reader has it.
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(
            source: BionicReading.script(startOn: settings.bionic),
            injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        guard !curling else { return }   // the curl's own silent move
        recordJump(to: locator)
        noteJump()
    }

    /// A footnote or endnote reference: show the note in a sheet instead of
    /// jumping to the end of the chapter and losing the place.
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: ReadiumShared.Link, content: String, referrer: String?) -> Bool {
        let text = BookText.plain(fromHTML: content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }   // nothing to show — follow the link as usual
        let label = referrer.map { BookText.plain(fromHTML: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
        footnote = Footnote(text: text, label: (label?.isEmpty ?? true) ? nil : label, link: link)
        return false
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard !curling else { return }   // the curl replays it on commit
        // the reader is away with the voice going on: the page behind it is stale, whatever it reports
        guard readAloud?.onScreen != false else { return }
        previousLocator = currentLocator
        currentLocator = locator
        narrationAhead = nil   // the page is where the voice was, or the reader moved it
        lastActivityAt = Date()
        // reading on from where a jump landed lets the way back go
        if history.back != nil { history.readOn(to: locator.locations.totalProgression ?? book.progression ?? 0) }
        book.locatorJSON = try? locator.jsonString()
        book.progression = locator.locations.totalProgression
        isCurrentLocationBookmarked = bookmark(matching: locator) != nil
        let entry = chapterEntry(for: locator)
        chapterTitle = entry?.link.title
        currentChapterID = entry?.id
        scheduleSave()
        beginSession()
        reading.moved(to: locator.locations.totalProgression)
        pushProgress()
    }

    /// Tell BookMaster how far the book has got, when that has changed enough to be worth a call.
    fileprivate func pushProgress() {
        let ref = book.bookMasterRef
        let progression = reading.reportable(book.progression ?? 0)
        // the push's own dedup still decides inside the task; this just skips
        // paying for a task the dedup would only throw away
        if BookMaster.shared.wantsProgress(bookKey: book.id.uuidString, percent: progression) {
            Task {
                await BookMaster.shared.syncProgress(
                    bookKey: book.id.uuidString, ref: ref, percent: progression, isAudio: false,
                    pinned: { [weak self] id in self?.pin(id) })
            }
        }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Log.error("reader", "navigator error: \(error)")
        notice = "This action isn't allowed in this publication."
    }
}
