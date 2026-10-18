import Foundation
import Observation

/// BookMaster sync, the Swift side of `docs/js/bookmaster.js`.
///
/// Every call goes through the Pages Function at `pageturner.pages.dev`, the
/// only place the bridge secret lives. Pushes the network can't take are parked
/// in a small on-disk queue and replayed oldest-first: progress is a position,
/// so a newer one replaces a queued one for the same book, while every session
/// and quote is its own event and always rides the queue.
@Observable
@MainActor
final class BookMaster {
    static let shared = BookMaster()

    static let bridge = URL(string: "https://pageturner.pages.dev/api/bookmaster")!
    static let queueMax = 50

    private(set) var user: BMUser?
    /// One-line message for the UI to show once (achievements, a dead link).
    var notice: String?
    /// Where the reader is, in Pageturner's words: library, reader, player, bookmaster, settings.
    var place = "library"

    var isLinked: Bool { user != nil }

    /// The reader's whole BookMaster shelf as of the last pull — kept so the Shelf screen opens at once, offline too.
    private(set) var shelfRows: [BMShelfRow] = []
    private let shelfKey = "bm-shelf-rows"

    #if DEBUG
    /// CI simulator run: a linked reader with a shelf and numbers, and no server (Debug/DebugScenario.swift).
    var debugTogether: BMTogether?
    var debugOverview: BMOverview?
    var debugDetail: BMBookDetail?
    var debugQuotes: [BMQuote]?
    var debugAchievements: [BMAchievementFull]?
    var debugStats: BMStatBlock?
    var debugPartnerShelf: BMPartnerShelf?
    var debugWrapped: BMWrapped?
    var debugRecommendations: BMRecommendations?
    var debugSeries: [BMSeries]?
    var debugSeriesDetail: BMSeriesDetail?

    func debugLink(shelf: [BMShelfRow], together: BMTogether?, overview: BMOverview?) {
        user = BMUser(username: "debug", displayName: "Debug Reader")
        shelfRows = shelf
        debugTogether = together
        debugOverview = overview
    }
    #endif

    func keepShelf(_ rows: [BMShelfRow]) {
        shelfRows = rows
        if let data = try? JSONEncoder().encode(rows) { defaults.set(data, forKey: shelfKey) }
    }

    /// Whether reading progress, sessions and presence are sent while linked.
    /// Off keeps the account linked (comments, suggestions and quotes still work)
    /// but stops the automatic reporting. Stored in UserDefaults, observable.
    var syncEnabled: Bool {
        get {
            access(keyPath: \.syncEnabled)
            return defaults.object(forKey: "bm-sync-enabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.syncEnabled) {
                defaults.set(newValue, forKey: "bm-sync-enabled")
            }
        }
    }

    private struct QueueEntry: Codable {
        var kind: String          // "progress" | "session" | "quote"
        var title: String         // progress de-dupe key
        var body: Data
        /// Which entry a drain step means after its await; older files have none.
        var id: UUID? = nil
        /// A session the reader logged by hand: it goes out even while automatic sync is paused. Older files have none.
        var manual: Bool? = nil
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let queueFileURL: URL?
    private let userKey = "bm-user"
    private let refusalKey = "bm-refusals"
    private var queue: [QueueEntry] = []
    private enum PushOutcome { case accepted(Data), refused }
    private var flushTask: Task<[UUID: PushOutcome], Never>?
    private var accountGeneration = 0
    private var warnedBroken = false
    private var lastPush: [String: (at: Date, percent: Double)] = [:]

    private var queueURL: URL {
        if let queueFileURL { return queueFileURL }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bm-queue.json")
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, queueURL: URL? = nil) {
        self.defaults = defaults
        self.session = session
        queueFileURL = queueURL
        if let data = defaults.data(forKey: userKey) {
            user = try? JSONDecoder().decode(BMUser.self, from: data)
        }
        if let data = defaults.data(forKey: shelfKey) {
            shelfRows = (try? JSONDecoder().decode([BMShelfRow].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: self.queueURL) {
            queue = ((try? JSONDecoder().decode([QueueEntry].self, from: data)) ?? []).map {
                var entry = $0
                entry.id = entry.id ?? UUID()
                return entry
            }
        }
    }

    // MARK: Linking

    /// Spend a one-time code BookMaster minted for this device.
    func redeem(code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, status) = try await post("link", body: body)
        guard (200..<300).contains(status) else {
            throw BMError.server(status, Self.errorMessage(data))
        }
        let linked = try JSONDecoder().decode(BMUser.self, from: data)
        setUser(linked)
        warnedBroken = false
        await flush()
    }

    /// Forget the account and anything still parked for it — those pushes
    /// belong to the reader who just left.
    func unlink() {
        setUser(nil)
        resetAccountCaches()
        queue.removeAll()
        lastPush.removeAll()
        try? FileManager.default.removeItem(at: queueURL)
    }

    /// What was kept for the reader who has left: their shelf, and which covers were sent for them.
    private func resetAccountCaches() {
        shelfRows = []
        defaults.removeObject(forKey: shelfKey)
        defaults.removeObject(forKey: "bm-covers-sent")
        defaults.removeObject(forKey: refusalKey)
        defaults.removeObject(forKey: refusalKey + "-at")
        lastPush.removeAll()
    }

    private func setUser(_ value: BMUser?) {
        accountGeneration += 1
        user = value
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: userKey)
        } else {
            defaults.removeObject(forKey: userKey)
        }
    }

    // MARK: Pushes

    /// Same dedup `syncProgress` applies, run synchronously — a page turn can
    /// ask before paying for the Task that would only bail out anyway.
    func wantsProgress(bookKey: String, percent: Double, force: Bool = false) -> Bool {
        guard user != nil, syncEnabled else { return false }
        if force { return true }
        let pct = (percent * 1000).rounded() / 10
        guard let last = lastPush[bookKey] else { return true }
        return last.percent != pct && Date().timeIntervalSince(last.at) >= 30
    }

    /// Reading position, throttled to once per 30s per book unless forced
    /// (book closed, playback paused). Fire-and-forget: never blocks reading.
    func syncProgress(
        bookKey: String, ref book: BMBookRef, percent: Double,
        isAudio: Bool, rating: Int? = nil, force: Bool = false,
        pinned: @escaping (String) -> Void
    ) async {
        guard let user, syncEnabled else { return }
        let pct = (percent * 1000).rounded() / 10
        if !force {
            if let last = lastPush[bookKey] {
                if last.percent == pct { return }
                if Date().timeIntervalSince(last.at) < 30 { return }
            }
        }
        lastPush[bookKey] = (Date(), pct)
        let payload = BMProgressPush(
            username: user.username, book: book, percent: pct,
            format: isAudio ? "audio" : "ebook",
            status: percent >= 0.995 ? "read" : nil, rating: rating)
        guard let body = try? JSONEncoder().encode(payload) else { return }
        guard let reply = await send(kind: "progress", title: book.title, body: body) else { return }
        if let id = reply.userBook?.id { pinned(id) }
    }

    /// A finished stretch of reading; BookMaster logs it as a real session.
    /// True when it landed or is parked to send later; false when sync is off,
    /// the reader isn't linked, or the bridge refused it.
    @discardableResult
    func syncSession(
        ref: BMBookRef, percentStart: Double, percentEnd: Double,
        minutes: Double, at: Date, manual: Bool = false
    ) async -> Bool {
        // pausing automatic sync must not swallow a session the reader typed in on purpose
        guard let user, syncEnabled || manual else { return false }
        let payload = BMSessionPush(
            username: user.username, book: ref,
            percentStart: (percentStart * 1000).rounded() / 10,
            percentEnd: (percentEnd * 1000).rounded() / 10,
            // the bridge refuses a day or more — and a longer sitting was a screen left on
            durationMinutes: minutes >= 0.5 ? min(Int(minutes.rounded()), 24 * 60) : nil,
            at: (at.timeIntervalSince1970 * 1000).rounded())
        guard let body = try? JSONEncoder().encode(payload) else { return false }
        let out = await submit(kind: "session", title: ref.title, body: body, manual: manual)
        if let data = out.data {
            announce((try? JSONDecoder().decode(BMPushReply.self, from: data))?.newAchievements)
        }
        return out.delivery != .failed
    }

    /// A book's jacket, for BookMaster's shelf. True when it was accepted or parked for later.
    func pushCover(ref: BMBookRef, jpeg: Data) async -> Bool {
        guard let user, syncEnabled else { return false }
        let payload = BMCoverPush(username: user.username, book: ref, coverB64: jpeg.base64EncodedString(), coverMime: "image/jpeg")
        guard let body = try? JSONEncoder().encode(payload) else { return false }
        return await sendRaw(kind: "cover", title: ref.title, body: body, park: false)
    }

    /// A line worth keeping, from the reader's selection menu.
    enum QuoteDelivery: Equatable {
        case sent, queued, failed

        var message: String {
            switch self {
            case .sent: return "Quote sent to BookMaster"
            case .queued: return "Quote saved — it will send when BookMaster is available"
            case .failed: return "Couldn’t send the quote"
            }
        }
    }

    @discardableResult
    func postQuote(ref: BMBookRef, content: String, percent: Double?) async -> QuoteDelivery {
        guard let user, !content.isEmpty else { return .failed }
        let payload = BMQuotePush(
            username: user.username, book: ref, content: content,
            percent: percent.map { $0 * 100 })
        guard let body = try? JSONEncoder().encode(payload) else { return .failed }
        return await submit(kind: "quote", title: ref.title, body: body).delivery
    }

    /// "I'm here" — never queued: a replayed beat lies about when you were there.
    /// True when it landed, so a missed one can be tried again while the
    /// presence window still covers the gap.
    @discardableResult
    func beat(place: String? = nil, leaving: Bool = false) async -> Bool {
        guard let user, syncEnabled else { return false }
        var json: [String: Any] = ["username": user.username]
        json["place"] = AppPrefs.sharePlace ? (place ?? self.place) : NSNull()
        if leaving { json["leaving"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return false }
        guard let (data, status) = try? await post("presence", body: body) else { return false }
        if !(200..<300).contains(status) {
            handleRefusal(status: status, data: data)
            return false
        }
        return true
    }

    // MARK: Reads

    /// The other reader, the suggestions waiting on you, and notices from the
    /// rest of the suite. A solo instance answers with no partner.
    func fetchTogether() async throws -> BMTogether {
        #if DEBUG
        if let debugTogether { return debugTogether }
        #endif
        guard let user else { throw BMError.notLinked }
        let (data, status) = try await get("together", query: ["username": user.username])
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return try JSONDecoder().decode(BMTogether.self, from: data)
    }

    /// Streaks, totals, goal progress and recent achievements.
    func fetchOverview() async throws -> BMOverview {
        #if DEBUG
        if let debugOverview { return debugOverview }
        #endif
        guard let user else { throw BMError.notLinked }
        let (data, status) = try await get("overview", query: ["username": user.username])
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return try JSONDecoder().decode(BMOverview.self, from: data)
    }

    /// BookMaster's own catalogue search: the reader's shelf first, then Open
    /// Library annotated with BookMaster's ids. Empty when not linked or offline.
    func searchCatalogue(title: String, author: String) async -> [BMSearchBook] {
        await searchCatalogueChecked(title: title, author: author) ?? []
    }

    /// Like `searchCatalogue`, but nil when the lookup failed (offline, refused),
    /// so a caller can tell a failure from no matches.
    func searchCatalogueChecked(title: String, author: String) async -> [BMSearchBook]? {
        guard let user else { return nil }
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return [] }
        let q = [name, author].filter { !$0.isEmpty }.joined(separator: " ")
        guard let (data, status) = try? await get("search", query: [
            "username": user.username, "title": name, "author": author, "q": q,
        ]), (200..<300).contains(status),
              let reply = try? JSONDecoder().decode(BMSearchReply.self, from: data)
        else { return nil }
        return reply.books
    }

    /// A wider lookup for the add-book flow — a free-text query or a bare
    /// ISBN from the scanner, answered by the same route.
    func searchExternal(_ query: String) async -> [BMSearchBook] {
        await searchCatalogue(title: query, author: "")
    }

    /// The shared thread on a book, gated the way BookMaster gates it: a note
    /// left further on than you are arrives sealed unless `reveal` is set.
    func fetchComments(ref: BMBookRef, reveal: Bool = false) async throws -> BMThread {
        guard let user else { throw BMError.notLinked }
        var query = ["username": user.username]
        if let pin = ref.userBookId {
            query["ub"] = pin
        } else {
            query["title"] = ref.title
            query["author"] = ref.author
        }
        if reveal { query["reveal"] = "1" }
        let (data, status) = try await get("comments", query: query)
        if status == 404, ref.userBookId != nil, Self.errorMessage(data) != "Unknown reader" {
            // the pinned shelf row is gone — look the book up by name instead
            var unpinned = ref
            unpinned.userBookId = nil
            return try await fetchComments(ref: unpinned, reveal: reveal)
        }
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return try JSONDecoder().decode(BMThread.self, from: data)
    }

    /// A note for whoever else has this book.
    func postComment(ref: BMBookRef, content: String) async throws {
        try await conversational("comment", ref: ref, extra: ["content": content])
    }

    /// "Read this next" — offer the book to the other reader.
    @discardableResult
    func suggest(ref: BMBookRef, note: String?) async throws -> String? {
        var extra: [String: Any] = [:]
        if let note, !note.isEmpty { extra["note"] = note }
        let data = try await conversational("nudge", ref: ref, extra: extra)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["to"] as? String
    }

    /// A POST that isn't worth queueing: conversational, cheap to retry by hand.
    @discardableResult
    private func conversational(_ path: String, ref: BMBookRef, extra: [String: Any]) async throws -> Data {
        guard let user else { throw BMError.notLinked }
        var json: [String: Any] = ["username": user.username, "title": ref.title, "author": ref.author]
        if let pin = ref.userBookId { json["user_book_id"] = pin }
        for (k, v) in extra { json[k] = v }
        let body = try JSONSerialization.data(withJSONObject: json)
        let (data, status) = try await postResolving(path, body: body)
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return data
    }

    /// Accept a suggestion onto the want-to-read shelf, or dismiss it.
    func answerNudge(id: String, accept: Bool) async throws {
        guard let user else { throw BMError.notLinked }
        let body = try JSONSerialization.data(withJSONObject: [
            "username": user.username, "id": id, "action": accept ? "accept" : "dismiss",
        ])
        let (data, status) = try await post("nudge-answer", body: body)
        guard (200..<300).contains(status) else {
            throw BMError.server(status, Self.errorMessage(data))
        }
    }

    // MARK: Chat

    /// The suite's shared room: the newest page, or what came `after` an id,
    /// or the page `before` one.
    func fetchChat(after: Int? = nil, before: Int? = nil, limit: Int = BMChat.pageSize) async throws -> BMChatRoom {
        var query = ["limit": String(limit)]
        if let after { query["after"] = String(after) }
        if let before { query["before"] = String(before) }
        return try await fetch("chat", query: query)
    }

    func sendChat(_ text: String) async throws -> BMChatMessage {
        let reply: BMChatSent = try await sendJSON("chat", json: ["body": text])
        return reply.message
    }

    /// "I have seen everything up to here."
    func markChatRead(upTo id: Int) async throws {
        try await sendJSON("chat-read", json: ["upTo": id])
    }

    /// Take back one of your own messages.
    func removeChat(id: Int) async throws {
        try await sendJSON("chat-remove", json: ["id": id])
    }

    // MARK: The deeper reads

    /// A decoded GET behind the link check and the refusal handling, so the
    /// deeper reads all read the same.
    private func fetch<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard let user else { throw BMError.notLinked }
        var q = query
        q["username"] = user.username
        let (data, status) = try await get(path, query: q)
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// One book the way BookMaster's detail page knows it — pinned by shelf
    /// row or catalogue id, or folded from a title the way a push resolves.
    func fetchBookDetail(pin: String? = nil, bookId: String? = nil,
                       title: String? = nil, author: String? = nil,
                       reveal: Bool = false) async throws -> BMBookDetail {
        #if DEBUG
        if let debugDetail { return debugDetail }
        #endif
        var query: [String: String] = [:]
        if let pin { query["ub"] = pin }
        else if let bookId { query["book"] = bookId }
        else if let title {
            query["title"] = title
            if let author { query["author"] = author }
        }
        if reveal { query["reveal"] = "1" }
        return try await fetch("book", query: query)
    }

    /// Every kept line and note, or only one shelf row's.
    func fetchQuotes(pin: String? = nil) async throws -> [BMQuote] {
        #if DEBUG
        if let debugQuotes { return debugQuotes }
        #endif
        var query: [String: String] = [:]
        if let pin { query["ub"] = pin }
        let reply: BMQuotesReply = try await fetch("quotes", query: query)
        return reply.quotes
    }

    /// The full badge wall — earned and how far the rest have got.
    func fetchAchievements() async throws -> [BMAchievementFull] {
        #if DEBUG
        if let debugAchievements { return debugAchievements }
        #endif
        let reply: BMAchievementsReply = try await fetch("achievements")
        return reply.achievements
    }

    /// The stat block the Progress pane leads with.
    func fetchStats() async throws -> BMStatBlock {
        #if DEBUG
        if let debugStats { return debugStats }
        #endif
        return try await fetch("stats")
    }

    /// The other reader's shelf, year and numbers.
    func fetchPartnerShelf() async throws -> BMPartnerShelf {
        #if DEBUG
        if let debugPartnerShelf { return debugPartnerShelf }
        #endif
        return try await fetch("partner-shelf")
    }

    /// The year in books — this year when none is named.
    func fetchWrapped(year: Int? = nil) async throws -> BMWrapped {
        #if DEBUG
        if let debugWrapped { return debugWrapped }
        #endif
        var query: [String: String] = [:]
        if let year { query["year"] = String(year) }
        return try await fetch("wrapped", query: query)
    }

    /// What to read next — the lanes BookMaster works out from both shelves.
    func fetchRecommendations() async throws -> BMRecommendations {
        #if DEBUG
        if let debugRecommendations { return debugRecommendations }
        #endif
        return try await fetch("recommendations")
    }

    /// A shelf change the way BookMaster's PUT /library/:id makes it:
    /// pin the row for a status, rating or up-next change (or `unshelve`),
    /// or pass a `ref` to put a book on a shelf the way a push resolves it.
    /// `rating` is a double Optional — `.some(nil)` clears the stars.
    /// Returns the row as it now stands; `extra` carries catalogue facts an
    /// add knows (cover_url, total_pages, published_year, description).
    @discardableResult
    func shelve(
        pin: String? = nil,
        ref: BMBookRef? = nil,
        status: BMShelfStatus? = nil,
        rating: Int?? = nil,
        upNext: Bool? = nil,
        format: String? = nil,
        unshelve: Bool = false,
        extra: [String: Any] = [:]
    ) async throws -> BMShelfWriteReply {
        guard let user else { throw BMError.notLinked }
        var json: [String: Any] = ["username": user.username]
        if let pin { json["user_book_id"] = pin }
        if let ref,
           let data = try? JSONEncoder().encode(ref),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in fields { json[k] = v }
        }
        for (k, v) in extra { json[k] = v }
        if let status { json["status"] = status.rawValue }
        if let rating { json["rating"] = rating ?? NSNull() }
        if let upNext { json["upNext"] = upNext }
        if let format { json["format"] = format }
        if unshelve { json["unshelve"] = true }

        let body = try JSONSerialization.data(withJSONObject: json)
        let (data, code) = try await postResolving("shelf", body: body)
        guard (200..<300).contains(code) else {
            handleRefusal(status: code, data: data)
            throw BMError.server(code, Self.errorMessage(data))
        }
        let reply = try JSONDecoder().decode(BMShelfWriteReply.self, from: data)
        announce(reply.newAchievements)
        // unlinked while this was out: the row belongs to a reader who is gone
        guard self.user?.username == user.username else { return reply }
        if unshelve, let pin { dropShelfRow(pin) }
        else if let row = reply.userBook { applyShelfRow(row) }
        return reply
    }

    /// A row that is yours to take back — a session logged by accident, a
    /// quote, a comment.
    enum BMRemovable: String {
        case session, quote, comment
    }

    func remove(_ kind: BMRemovable, id: String) async throws {
        guard let user else { throw BMError.notLinked }
        let body = try JSONSerialization.data(withJSONObject: [
            "username": user.username, "kind": kind.rawValue, "id": id,
        ])
        let (data, status) = try await post("remove", body: body)
        guard (200..<300).contains(status) else {
            throw BMError.server(status, Self.errorMessage(data))
        }
    }

    /// One row changed, straight into the cached shelf so screens stay right
    /// before the next pull — and offline too.
    private func applyShelfRow(_ row: BMShelfRow) {
        if let i = shelfRows.firstIndex(where: { $0.userBookId == row.userBookId }) {
            shelfRows[i] = row
        } else {
            shelfRows.append(row)
        }
        if let data = try? JSONEncoder().encode(shelfRows) { defaults.set(data, forKey: shelfKey) }
    }

    private func dropShelfRow(_ pin: String) {
        shelfRows.removeAll { $0.userBookId == pin }
        if let data = try? JSONEncoder().encode(shelfRows) { defaults.set(data, forKey: shelfKey) }
    }

    // MARK: - The wider bridge

    /// Named runs the reader holds a book in, with how far each has gone.
    func fetchSeries() async throws -> [BMSeries] {
        #if DEBUG
        if let debugSeries { return debugSeries }
        #endif
        let reply: BMSeriesReply = try await fetch("series")
        return reply.series
    }

    /// One run with its books, each marked by the caller's row on it.
    func fetchSeriesDetail(id: String) async throws -> BMSeriesDetail {
        #if DEBUG
        if let debugSeriesDetail { return debugSeriesDetail }
        #endif
        return try await fetch("series-detail", query: ["id": id])
    }

    /// A new named run — series belong to the catalogue, not a reader.
    @discardableResult
    func createSeries(name: String, author: String? = nil, totalBooks: Int? = nil) async throws -> String {
        var json: [String: Any] = ["name": name]
        if let author { json["author"] = author }
        if let totalBooks { json["total_books"] = totalBooks }
        struct Reply: Decodable { var id: String }
        let reply: Reply = try await sendJSON("series", json: json)
        return reply.id
    }

    /// File a shelved book into a run, or take it out — `remove: true` unwelcomes it.
    func setSeriesBook(series: String, book: String, position: Int? = nil, remove: Bool = false) async throws {
        var json: [String: Any] = ["series_id": series, "book_id": book]
        if let position { json["position"] = position }
        if remove { json["remove"] = true }
        try await sendJSON("series-book", json: json)
    }

    /// The queue in its new order — add, drop and reshuffle are this one
    /// write, exactly the web's PUT /up-next. Answers with the queue back.
    @discardableResult
    func setUpNext(_ ids: [String]) async throws -> [BMUpNextBook] {
        let reply: BMUpNextReply = try await sendJSON("up-next", json: ["ids": ids])
        guard user != nil else { return reply.books }
        // Mirror the order into the cached shelf so screens stay right
        // before the next pull — and offline too.
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset + 1) })
        for i in shelfRows.indices { shelfRows[i].upNext = rank[shelfRows[i].userBookId] }
        if let data = try? JSONEncoder().encode(shelfRows) { defaults.set(data, forKey: shelfKey) }
        return reply.books
    }

    /// A goal made from the phone — the same insert the web's goal card sends.
    @discardableResult
    func setGoal(type: String, target: Int, year: Int? = nil,
                 month: Int? = nil, label: String? = nil) async throws -> String {
        var json: [String: Any] = ["type": type, "target": target]
        if let year { json["year"] = year }
        if let month { json["month"] = month }
        if let label { json["label"] = label }
        struct Reply: Decodable { var id: String }
        let reply: Reply = try await sendJSON("goal", json: json)
        return reply.id
    }

    /// Take a goal back — the caller's rows only, the bridge guards that.
    func removeGoal(id: String) async throws {
        try await sendJSON("goal", json: ["id": id, "remove": true])
    }

    /// The catalogue row's facts — only for a book on the reader's shelf.
    /// `coverPick` says a new jacket URL should win even over pushed art.
    func editBook(_ bookId: String, title: String, author: String,
                  totalPages: Int? = nil, publishedYear: Int? = nil,
                  isbn: String? = nil, genres: [String] = [],
                  coverUrl: String? = nil, coverPick: Bool = false) async throws {
        var json: [String: Any] = [
            "book_id": bookId, "title": title, "author": author, "genres": genres,
        ]
        if let totalPages { json["total_pages"] = totalPages }
        if let publishedYear { json["published_year"] = publishedYear }
        if let isbn { json["isbn"] = isbn }
        if let coverUrl { json["cover_url"] = coverUrl }
        if coverPick { json["cover_pick"] = true }
        try await sendJSON("edit-book", json: json)
    }

    /// The whole library as a file to share — "csv" for a spreadsheet,
    /// anything else for the full JSON archive.
    func exportData(format: String = "json") async throws -> Data {
        guard let user else { throw BMError.notLinked }
        let (data, status) = try await get(
            "export", query: ["username": user.username, "format": format])
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return data
    }

    /// The one profile field a phone may set — the public name. The stored
    /// user updates too, so screens show it before the next pull.
    func updateProfile(displayName: String) async throws {
        try await sendJSON("profile", json: ["display_name": displayName])
        user?.displayName = displayName
        if let user, let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: userKey)
        }
    }

    /// A Goodreads export's rows, already parsed on the phone — `preview`
    /// counts without writing, the real send shelves through the same
    /// find-or-create rules the web import uses.
    @discardableResult
    func importRows(_ rows: [BMImportRow], preview: Bool = false) async throws -> BMImportReply {
        let encoded = try rows.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
        let reply: BMImportReply = try await sendJSON(
            "import", json: ["rows": encoded, "preview": preview])
        announce(reply.newAchievements)
        return reply
    }

    /// POST a JSON object with the reader's username folded in — the write
    /// shape every non-push bridge route takes.
    @discardableResult
    private func sendJSON<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        guard let user else { throw BMError.notLinked }
        var merged = json
        merged["username"] = user.username
        let body = try JSONSerialization.data(withJSONObject: merged)
        let (data, status) = try await post(path, body: body)
        guard (200..<300).contains(status) else {
            handleRefusal(status: status, data: data)
            throw BMError.server(status, Self.errorMessage(data))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `sendJSON` for writes whose only answer that matters is success.
    private func sendJSON(_ path: String, json: [String: Any]) async throws {
        struct OK: Decodable { var ok: Bool? }
        let _: OK = try await sendJSON(path, json: json)
    }

    // MARK: Sending

    /// Send a push, parking it when the network can't take it. Returns the
    /// reply when the bridge accepted it, nil when parked or refused.
    private func send(kind: String, title: String, body: Data) async -> BMPushReply? {
        guard let data = await submit(kind: kind, title: title, body: body).data else { return nil }
        let reply = try? JSONDecoder().decode(BMPushReply.self, from: data)
        announce(reply?.newAchievements)
        return reply
    }

    private func submit(kind: String, title: String, body: Data, manual: Bool = false) async -> (delivery: QuoteDelivery, data: Data?) {
        guard let user, Self.owner(of: body) == user.username else { return (.failed, nil) }
        let generation = accountGeneration
        let id = UUID()
        enqueue(QueueEntry(kind: kind, title: title, body: body, id: id, manual: manual ? true : nil))
        let results = await drainQueue()
        guard generation == accountGeneration else { return (.failed, nil) }
        if case let .accepted(data) = results[id] { return (.sent, data) }
        return (queue.contains { $0.id == id } ? .queued : .failed, nil)
    }

    /// `send` for pushes whose only answer that matters is success.
    ///
    /// `park: false` is for pushes that are worth trying again later but not worth a place in the line (a cover is
    /// large, and many of them would push real entries out): the answer is true only when it went through.
    private func sendRaw(kind: String, title: String, body: Data, park: Bool = true) async -> Bool {
        if park { return await submit(kind: kind, title: title, body: body).delivery != .failed }
        let generation = accountGeneration
        await flush()
        guard generation == accountGeneration, Self.owner(of: body) == user?.username,
              !queue.contains(where: { syncEnabled || $0.kind == "quote" || $0.manual == true }) else { return false }
        do {
            let (data, status) = try await postResolving(kind, body: body)
            guard generation == accountGeneration else { return false }
            if !(200..<300).contains(status) {
                handleRefusal(status: status, data: data)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Drain the queue oldest-first, stopping at the first push the network
    /// still won't take — order is the point. A 4xx can never succeed, so it is
    /// dropped rather than left to block the line behind it.
    func flush() async {
        _ = await drainQueue()
    }

    private func drainQueue() async -> [UUID: PushOutcome] {
        if let flushTask { return await flushTask.value }
        let task = Task {
            let result = await drain()
            flushTask = nil
            return result
        }
        flushTask = task
        return await task.value
    }

    private func drain() async -> [UUID: PushOutcome] {
        var outcomes: [UUID: PushOutcome] = [:]
        while let user {
            queue.removeAll { Self.owner(of: $0.body) != user.username }
            saveQueue()
            guard let head = queue.first(where: { syncEnabled || $0.kind == "quote" || $0.manual == true }) else { break }
            let generation = accountGeneration
            let result: (Data, Int)
            do { result = try await postResolving(head.kind, body: head.body) } catch { break }
            guard generation == accountGeneration else { continue }
            if Self.retriable(result.1) { break }
            // An unknown reader may be a blip: keep the entry until the link is declared dead.
            if result.1 == 404, Self.errorMessage(result.0) == "Unknown reader" {
                handleRefusal(status: result.1, data: result.0)
                break
            }
            // by identity: the queue may have changed while that was in flight
            queue.removeAll { $0.id == head.id }
            saveQueue()
            if let id = head.id {
                outcomes[id] = (200..<300).contains(result.1) ? .accepted(result.0) : .refused
            }
            if !(200..<300).contains(result.1) {
                handleRefusal(status: result.1, data: result.0)
            }
        }
        return outcomes
    }

    private func enqueue(_ entry: QueueEntry) {
        var entry = entry
        if entry.id == nil { entry.id = UUID() }
        if entry.kind == "progress" {
            // a rating parked with the older position rides on the newer one that replaces it
            if let older = queue.last(where: { $0.kind == "progress" && Self.sameBook($0.body, entry.body) }) {
                entry.body = Self.keepingRating(from: older.body, in: entry.body)
            }
            queue.removeAll { $0.kind == "progress" && Self.sameBook($0.body, entry.body) }
        }
        queue.append(entry)
        while queue.count > Self.queueMax { queue.removeFirst() }
        saveQueue()
    }

    private func saveQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    /// A 404 "Unknown reader" is a dead link — stop failing on every page turn.
    /// One refusal can be a blip (a mid-deploy proxy hop, a flag window), so
    /// the link is only severed after three in a row; any success resets it.
    private func handleRefusal(status: Int, data: Data) {
        guard status == 404, Self.errorMessage(data) == "Unknown reader" else { return }
        // at most one strike a minute, so a burst of calls in one blip is one strike
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: refusalKey + "-at")
        guard now - last >= 60 || now < last else { return }
        defaults.set(now, forKey: refusalKey + "-at")
        let strikes = defaults.integer(forKey: refusalKey) + 1
        defaults.set(strikes, forKey: refusalKey)
        Log.event("bookmaster", "link refused (404 Unknown reader) — strike \(strikes)")
        guard strikes >= 3 else { return }
        Log.event("bookmaster", "link dead after \(strikes) refusals — unlinked")
        setUser(nil)
        resetAccountCaches()
        queue.removeAll()
        try? FileManager.default.removeItem(at: queueURL)
        if !warnedBroken {
            warnedBroken = true
            notice = "BookMaster link broke — link again in Settings"
        }
    }

    /// A pinned shelf row that is gone (deleted on BookMaster, or pinned by a
    /// reader who has since unlinked) answers 404 forever. Retry once without
    /// the pin so the title and author re-resolve it; the reply carries the
    /// right pin, which the caller stores.
    private func postResolving(_ path: String, body: Data) async throws -> (Data, Int) {
        let first = try await post(path, body: body)
        guard first.1 == 404, Self.errorMessage(first.0) != "Unknown reader",
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              json.removeValue(forKey: "user_book_id") != nil,
              let retry = try? JSONSerialization.data(withJSONObject: json)
        else { return first }
        return try await post(path, body: retry)
    }

    private func announce(_ achievements: [BMAchievement]?) {
        guard let a = achievements?.first else { return }
        notice = "\(a.icon ?? "🏆") \(a.name ?? "Achievement earned")"
    }

    /// Worth trying again later: the server or the path to it is struggling.
    private static func retriable(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    private static func owner(of body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["username"] as? String
    }

    /// `new`, with the rating `old` carried if `new` carries none.
    private static func keepingRating(from old: Data, in new: Data) -> Data {
        guard var fresh = (try? JSONSerialization.jsonObject(with: new)) as? [String: Any], fresh["rating"] == nil,
              let before = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
              let rating = before["rating"]
        else { return new }
        fresh["rating"] = rating
        return (try? JSONSerialization.data(withJSONObject: fresh)) ?? new
    }

    private static func sameBook(_ left: Data, _ right: Data) -> Bool {
        guard let a = (try? JSONSerialization.jsonObject(with: left)) as? [String: Any],
              let b = (try? JSONSerialization.jsonObject(with: right)) as? [String: Any],
              (a["username"] as? String) == (b["username"] as? String) else { return false }
        if let x = a["user_book_id"] as? String, let y = b["user_book_id"] as? String { return x == y }
        if let x = a["open_library_id"] as? String, let y = b["open_library_id"] as? String { return x == y }
        if let x = a["isbn"] as? String, let y = b["isbn"] as? String,
           let first = ISBN.canonical(x), let second = ISBN.canonical(y) { return first == second }
        return (a["title"] as? String) == (b["title"] as? String)
            && sendableAuthor(a["author"] as? String ?? "") == sendableAuthor(b["author"] as? String ?? "")
    }

    private static func errorMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    // MARK: Transport

    func get(_ path: String, query: [String: String]) async throws -> (Data, Int) {
        var parts = URLComponents(url: Self.bridge.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 20
        if let key = user?.deviceKey { request.setValue(key, forHTTPHeaderField: "x-pt-key") }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { clearRefusals() }
        return (data, code)
    }

    private func post(_ path: String, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.bridge.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        request.timeoutInterval = 20
        if let key = user?.deviceKey { request.setValue(key, forHTTPHeaderField: "x-pt-key") }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { clearRefusals() }
        return (data, code)
    }

    /// One landed call proves the link is alive — drop the dead-link count.
    private func clearRefusals() {
        if defaults.integer(forKey: refusalKey) != 0 {
            defaults.removeObject(forKey: refusalKey)
        defaults.removeObject(forKey: refusalKey + "-at")
        }
    }
}
