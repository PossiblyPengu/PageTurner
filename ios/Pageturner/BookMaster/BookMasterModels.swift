import Foundation
#if canImport(Security)
import Security
#endif

/// The reader this device is linked as. The bridge secret lives in the Pages
/// Function; `deviceKey` is this device's own credential, minted at link and
/// sent as X-PT-Key — BookMaster requires it once PAGETURNER_REQUIRE_KEY is on.
struct BMUser: Codable, Equatable {
    var username: String
    var displayName: String?
    var deviceKey: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case deviceKey = "device_key"
    }
}

/// The per-device key BookMaster mints at link. A credential, so it lives in the
/// Keychain — this device only, while it is unlocked — rather than inside the account
/// record in the settings plist. (The check build has no Keychain: there the key simply
/// is not persisted, which changes nothing a check can see.)
enum BMKeychain {
    private static let service = "io.github.possiblypengu.pageturner.bookmaster"

    static func key(for username: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    static func setKey(_ key: String?, for username: String) {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // the key names this device: a backup or another device has no use for it
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }
}

/// An achievement the bridge hydrated for display.
struct BMAchievement: Decodable, Hashable {
    var id: String?
    var name: String?
    var icon: String?
}

struct BMUserBook: Decodable {
    var id: String?
}

/// What `progress` and `session` answer with.
struct BMPushReply: Decodable {
    var userBook: BMUserBook?
    var newAchievements: [BMAchievement]?
}

/// The fields every push uses to say which book it means — identity first,
/// then the catalogue facts this copy already knows, so a push fills gaps in
/// BookMaster's row rather than leaving them for a later lookup.
struct BMBookRef: Encodable {
    var title: String
    var author: String
    var isbn: String?
    var openLibraryId: String?
    /// The shelf row BookMaster gave back last time; pinning beats guessing.
    var userBookId: String?
    var bookDescription: String?
    var publishedYear: Int?
    /// A real page count, when the file has one — BookMaster converts the
    /// pushed percent into pages so a PDF or a page-listed EPUB can say
    /// "page 138 of 320" rather than a bare 43%.
    var totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case title, author, isbn
        case openLibraryId = "open_library_id"
        case userBookId = "user_book_id"
        case bookDescription = "description"
        case publishedYear = "published_year"
        case totalPages = "total_pages"
    }
}

struct BMProgressPush: Encodable {
    var username: String
    var book: BMBookRef
    var percent: Double
    var format: String
    var status: String?
    var rating: Int?
    var coverB64: String?
    var coverMime: String?

    enum CodingKeys: String, CodingKey {
        case username, percent, format, status, rating
        case coverB64 = "cover_b64"
        case coverMime = "cover_mime"
    }

    // The book fields sit at the top level of the JSON, not under "book".
    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(percent, forKey: .percent)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(coverB64, forKey: .coverB64)
        try c.encodeIfPresent(coverMime, forKey: .coverMime)
    }
}

/// A jacket for BookMaster to show on the shelf: the book fields at the top level, then the image.
struct BMCoverPush: Encodable {
    var username: String
    var book: BMBookRef
    var coverB64: String
    var coverMime: String

    enum CodingKeys: String, CodingKey {
        case username
        case coverB64 = "cover_b64"
        case coverMime = "cover_mime"
    }

    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(coverB64, forKey: .coverB64)
        try c.encode(coverMime, forKey: .coverMime)
    }
}

struct BMSessionPush: Encodable {
    var username: String
    var book: BMBookRef
    var percentStart: Double
    var percentEnd: Double
    var durationMinutes: Int?
    /// When the stretch ended, in milliseconds since 1970 — what the bridge requires.
    var at: Double

    enum CodingKeys: String, CodingKey {
        case username, at
        case percentStart = "percent_start"
        case percentEnd = "percent_end"
        case durationMinutes = "duration_minutes"
    }

    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(percentStart, forKey: .percentStart)
        try c.encode(percentEnd, forKey: .percentEnd)
        try c.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try c.encode(at, forKey: .at)
    }
}

struct BMQuotePush: Encodable {
    var username: String
    var book: BMBookRef
    var content: String
    var percent: Double?

    enum CodingKeys: String, CodingKey { case username, content, percent }

    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(percent, forKey: .percent)
    }
}

enum BMError: LocalizedError {
    case notLinked
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notLinked: return "Not linked to BookMaster"
        case let .server(code, message): return message ?? "BookMaster answered \(code)"
        }
    }
}

/// "Herbert, Frank" and "Frank Herbert (Author)" both go up as "Frank Herbert",
/// so a row created by a push doesn't read backwards forever.
func sendableAuthor(_ raw: String) -> String {
    var clean = raw
    while let open = clean.firstIndex(of: "("), let close = clean[open...].firstIndex(of: ")") {
        clean.replaceSubrange(open...close, with: " ")
    }
    clean = clean.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let parts = clean.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    let ambiguous = clean.contains(";") || clean.contains("&")
    if parts.count == 2, !ambiguous, !parts[0].isEmpty, !parts[1].isEmpty {
        return "\(parts[1]) \(parts[0])"
    }
    return clean
}

// MARK: - Together

struct BMReading: Decodable, Hashable {
    var title: String
    var author: String?
    var format: String?
    var percent: Double?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, author, format, percent
        case updatedAt = "updated_at"
    }
}

/// One app's heartbeat for a reader, the way the suite keeps it.
struct BMAppBeat: Decodable, Hashable {
    var online: Bool
    var place: String?
    var lastSeenAt: Double

    enum CodingKeys: String, CodingKey {
        case online, place
        case lastSeenAt = "last_seen_at"
    }
}

struct BMPartner: Decodable {
    var name: String
    var online: Bool
    /// Where they are across the suite — keyed "bookmaster" / "quest-log" /
    /// "kindred" / "pageturner". Absent on an older bridge.
    var apps: [String: BMAppBeat]?
    var reading: BMReading?
}

/// The caller's own suite card — which other apps they are in right now.
struct BMYou: Decodable, Hashable {
    var apps: [String: BMAppBeat]?
}

struct BMNudge: Decodable, Identifiable, Hashable {
    var id: String
    var note: String?
    var fromName: String
    var title: String
    var author: String?
    var coverUrl: String?
    var openLibraryId: String?
    var isbn: String?

    enum CodingKeys: String, CodingKey {
        case id, note, fromName, title, author, isbn
        case coverUrl = "cover_url"
        case openLibraryId = "openLibraryId"
    }
}

/// A line another suite app wants this one to show.
struct BMNotice: Decodable, Identifiable, Hashable {
    var id: String
    var app: String
    var text: String
    /// Where it opens, a path inside its own app.
    var path: String? = nil
}

/// A suggestion you sent and have not heard back about yet.
struct BMSentNudge: Decodable, Identifiable, Hashable {
    var id: String
    var status: String
    var note: String?
    var title: String
    var toName: String
}

struct BMTogether: Decodable {
    var partner: BMPartner?
    /// The caller's own suite presence, for their side of the comparison.
    var you: BMYou?
    var nudges: [BMNudge]
    /// Suggestions of yours still out with the other reader.
    var sent: [BMSentNudge]
    var notices: [BMNotice]

    enum CodingKeys: String, CodingKey {
        case partner, you, nudges, sent, notices
    }

    init(partner: BMPartner?, you: BMYou? = nil, nudges: [BMNudge], sent: [BMSentNudge], notices: [BMNotice]) {
        self.partner = partner
        self.you = you
        self.nudges = nudges
        self.sent = sent
        self.notices = notices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partner = try c.decodeIfPresent(BMPartner.self, forKey: .partner)
        you = try c.decodeIfPresent(BMYou.self, forKey: .you)
        nudges = try c.decodeIfPresent([BMNudge].self, forKey: .nudges) ?? []
        sent = try c.decodeIfPresent([BMSentNudge].self, forKey: .sent) ?? []
        notices = try c.decodeIfPresent([BMNotice].self, forKey: .notices) ?? []
    }
}

// MARK: - Comments

struct BMComment: Decodable, Identifiable, Hashable {
    var id: String
    /// Nil while sealed: a note left further on than the reader has got.
    var content: String?
    var displayName: String
    var userId: String
    var atPercent: Double?
    var ahead: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, ahead
        case displayName = "display_name"
        case userId = "user_id"
        case atPercent = "at_percent"
    }
}

struct BMThread: Decodable {
    var comments: [BMComment]
    var you: String?
}

// MARK: - Chat

/// One message in the suite's shared room.
struct BMChatMessage: Decodable, Identifiable, Hashable {
    var id: Int
    var userId: String
    var name: String
    var body: String
    /// The app it was written in — "bookmaster", "kindred", "pageturner"…
    var app: String
    /// Milliseconds since 1970, the way every suite clock is kept.
    var at: Double

    enum CodingKeys: String, CodingKey {
        case id, name, body, app, at
        case userId = "user_id"
    }

    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

struct BMChatPerson: Decodable, Hashable {
    var id: String
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// The newest message each reader has seen.
struct BMChatRead: Decodable, Hashable {
    var mine: Int
    var theirs: Int
}

/// The room as one screen needs it: the messages, who is in it, who has read what.
struct BMChatRoom: Decodable {
    var messages: [BMChatMessage]
    var me: BMChatPerson
    var partner: BMChatPerson?
    var read: BMChatRead
    var unread: Int
    /// Whether `messages` begins at the first message there is.
    var complete: Bool
    /// Which part of Quest Log ("giver" or "adventurer") BookMaster knows this reader plays, for its private room.
    var questLogRole: String?
}

struct BMChatSent: Decodable {
    var message: BMChatMessage
}

// MARK: - Overview (stats)

struct BMStats: Decodable {
    var currentStreak: Double
    var longestStreak: Double
    var booksFinished: Double
    var minutesRead: Double
    var quotesSaved: Double
}

struct BMGoal: Decodable, Identifiable {
    var id: String?
    var type: String
    var target: Double?
    var current: Double
    var progress: Double
    /// The row's own fields, for the editor: which year/month it counts and
    /// the name a reader gave it.
    var year: Int?
    var month: Int?
    var label: String?

    var stableId: String { id ?? type }

    /// The three kinds BookMaster knows — the bridge's GOAL_TYPES, mirrored.
    enum Kind: String, CaseIterable, Identifiable {
        case yearlyBooks = "yearly_books"
        case yearlyPages = "yearly_pages"
        case monthlyBooks = "monthly_books"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .yearlyBooks: return "Books this year"
            case .yearlyPages: return "Pages this year"
            case .monthlyBooks: return "Books this month"
            }
        }
    }
}

struct BMEarned: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String?
}

struct BMOverview: Decodable {
    var stats: BMStats
    var goals: [BMGoal]
    var recentAchievements: [BMEarned]
    /// The caller's own year, for a comparison card — the same numbers the
    /// partner card reads from partner-shelf.
    var year: Int?
    var booksThisYear: Int?
    var pagesThisYear: Double?
}

// MARK: - The deep bridge

/// What POST /shelf answers: the row as it now stands, and any badges the
/// change earned — the same reply a progress push gets, with the fuller row.
struct BMShelfWriteReply: Decodable {
    var userBook: BMShelfRow?
    var newAchievements: [BMAchievement]?
}

/// What the row means for a status change. `abandoned` is BookMaster's word
/// for the shelf a reader set a book aside on.
enum BMShelfStatus: String, CaseIterable, Identifiable {
    case wantToRead = "want_to_read"
    case reading
    case read
    case abandoned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wantToRead: return "Want to read"
        case .reading: return "Reading"
        case .read: return "Read"
        case .abandoned: return "Abandoned"
        }
    }

    /// Cramped controls only: a segmented picker truncates "Want to read".
    var shortLabel: String {
        switch self {
        case .wantToRead: return "To read"
        default: return label
        }
    }
}

/// The catalogue card `GET /book` carries for a row: the facts a detail page
/// leads with, none of them yours.
struct BMCatalogue: Decodable, Hashable {
    var id: String?
    var title: String?
    var author: String?
    var coverUrl: String?
    var description: String?
    var totalPages: Int?
    var publishedYear: Int?
    var openLibraryId: String?
    var isbn: String?
    /// A JSON array string, the way the catalogue stores it.
    var genres: String?

    enum CodingKeys: String, CodingKey {
        case id, title, author, description, genres, isbn
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
        case publishedYear = "published_year"
        case openLibraryId = "open_library_id"
    }

    var genreList: [String] {
        guard let genres, let data = genres.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }
}

/// Where the other reader has the same book, when they do.
struct BMTheirs: Decodable, Hashable {
    var name: String
    var status: String
    var rating: Int?
    var percent: Double?
    var finishDate: String?

    enum CodingKeys: String, CodingKey {
        case name, status, rating, percent
        case finishDate = "finish_date"
    }
}

/// A stretch of reading logged on BookMaster.
struct BMSession: Decodable, Identifiable, Hashable {
    var id: String
    var pagesStart: Double?
    var pagesEnd: Double?
    var durationMinutes: Int?
    var sessionDate: String?
    var listenedStart: Double?
    var listenedEnd: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case pagesStart = "pages_start"
        case pagesEnd = "pages_end"
        case durationMinutes = "duration_minutes"
        case sessionDate = "session_date"
        case listenedStart = "listened_start"
        case listenedEnd = "listened_end"
    }

    var pagesRead: Double? {
        guard let s = pagesStart, let e = pagesEnd else { return nil }
        return max(0, e - s)
    }
}

/// A kept line or note, as `GET /book` and `GET /quotes` hand it over.
struct BMQuote: Decodable, Identifiable, Hashable {
    var id: String
    /// Present on the whole-list read: which shelf row it hangs on.
    var userBookId: String?
    var content: String
    var type: String?
    /// `page_number` on the per-book read, `pageNumber` on the list read.
    var pageNumber: Int?
    var createdAt: String?
    /// The book's title and author on the list read.
    var title: String?
    var author: String?

    enum CodingKeys: String, CodingKey {
        case id, content, type, title, author, pageNumber
        case userBookId
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        userBookId = try c.decodeIfPresent(String.self, forKey: .userBookId)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        if let n = try c.decodeIfPresent(Int.self, forKey: .pageNumber) {
            pageNumber = n
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            pageNumber = try alt.decodeIfPresent(Int.self, forKey: .page_number)
        }
    }

    private enum AltKeys: String, CodingKey { case page_number }

    var isNote: Bool { type == "note" }
}

/// A note on the shared thread as `GET /book` hands it over — `content` nil
/// while it is sealed ahead of you.
struct BMBookComment: Decodable, Identifiable, Hashable {
    var id: String
    var content: String?
    var createdAt: String?
    var userId: String
    var displayName: String
    var atPercent: Double?
    var atPage: Int?
    var ahead: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, ahead
        case createdAt = "created_at"
        case userId = "user_id"
        case displayName = "display_name"
        case atPercent = "at_percent"
        case atPage = "at_page"
    }
}

/// Everything the detail pane knows about one book.
struct BMBookDetail: Decodable {
    var catalogue: BMCatalogue?
    var book: BMShelfRow?
    var theirs: BMTheirs?
    var sessions: [BMSession]
    var quotes: [BMQuote]
    var comments: [BMBookComment]
    /// Your user id, for "this note is mine" and unsealed checks.
    var you: String?
    /// How far through you are, in percent — what the spoiler gate used.
    var atPercent: Double?

    enum CodingKeys: String, CodingKey {
        case catalogue, book, theirs, sessions, quotes, comments, you
        case atPercent = "at_percent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalogue = try c.decodeIfPresent(BMCatalogue.self, forKey: .catalogue)
        book = try c.decodeIfPresent(BMShelfRow.self, forKey: .book)
        theirs = try c.decodeIfPresent(BMTheirs.self, forKey: .theirs)
        sessions = try c.decodeIfPresent([BMSession].self, forKey: .sessions) ?? []
        quotes = try c.decodeIfPresent([BMQuote].self, forKey: .quotes) ?? []
        comments = try c.decodeIfPresent([BMBookComment].self, forKey: .comments) ?? []
        you = try c.decodeIfPresent(String.self, forKey: .you)
        atPercent = try c.decodeIfPresent(Double.self, forKey: .atPercent)
    }
}

struct BMQuotesReply: Decodable {
    var quotes: [BMQuote]
}

/// A badge on the wall: `earned` ones carry their date, the rest a 0–1 of
/// how close they are.
struct BMAchievementFull: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var description: String?
    var icon: String?
    var category: String?
    var xpReward: Int?
    var earned: Bool
    var earnedAt: String?
    var progress: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, category, earned, progress
        case xpReward = "xp_reward"
        case earnedAt = "earned_at"
    }
}

struct BMAchievementsReply: Decodable {
    var achievements: [BMAchievementFull]
}

/// One active day in the last month.
struct BMActivityDay: Decodable, Hashable {
    var sessionDate: String
    var pages: Double?
    var sessions: Int?

    enum CodingKeys: String, CodingKey {
        case pages, sessions
        case sessionDate = "session_date"
    }
}

/// A book on the go, as the stats read names it.
struct BMReadingRow: Decodable, Identifiable, Hashable {
    var id: String
    var currentPage: Double?
    /// The e-reader's own number for a page-less book — kept beside the page
    /// count rather than folded into it.
    var pushedPercent: Double?
    var status: String?
    var format: String?
    var title: String
    var author: String?
    var coverUrl: String?
    var totalPages: Int?
    /// When the row last moved, for "2h ago" beside a book on the go.
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, status, format, title, author
        case currentPage = "current_page"
        case pushedPercent = "percent"
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
        case updatedAt = "updated_at"
    }

    /// The rule the bridge's `withPercent` spells: real pages when the book
    /// knows them, the pushed percent when it does not, the audio convention
    /// (current_page holds the percent) after that.
    var percent: Double? {
        if let currentPage, let totalPages, totalPages > 0 {
            return currentPage / Double(totalPages) * 100
        }
        if let pushedPercent { return pushedPercent }
        return format == "audio" ? currentPage : nil
    }
}

/// The Progress pane: `getUserStats`'s whole block plus XP, level, the last
/// month's days and what is on the go. Every counter optional — an older
/// bridge answers fewer.
struct BMStatBlock: Decodable {
    var xp: Double
    var level: Int
    var xpForNext: Double?
    var xpProgress: Double?
    var totalBooksAdded: Double?
    var booksFinished: Double?
    var totalPages: Double?
    var currentStreak: Double?
    var longestStreak: Double?
    var genresRead: Double?
    var sessionsLogged: Double?
    var quotesSaved: Double?
    var booksReread: Double?
    var nudgesSent: Double?
    var nudgesTaken: Double?
    var commentsPosted: Double?
    var minutesRead: Double?
    var ratingsGiven: Double?
    var authorsRead: Double?
    var recentActivity: [BMActivityDay]
    var currentlyReading: [BMReadingRow]

    enum CodingKeys: String, CodingKey {
        case xp, level, xpForNext, xpProgress, totalBooksAdded, booksFinished
        case totalPages, currentStreak, longestStreak, genresRead, sessionsLogged
        case quotesSaved, booksReread, nudgesSent, nudgesTaken, commentsPosted
        case minutesRead, ratingsGiven, authorsRead, recentActivity, currentlyReading
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xp = try c.decodeIfPresent(Double.self, forKey: .xp) ?? 0
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        xpForNext = try c.decodeIfPresent(Double.self, forKey: .xpForNext)
        xpProgress = try c.decodeIfPresent(Double.self, forKey: .xpProgress)
        totalBooksAdded = try c.decodeIfPresent(Double.self, forKey: .totalBooksAdded)
        booksFinished = try c.decodeIfPresent(Double.self, forKey: .booksFinished)
        totalPages = try c.decodeIfPresent(Double.self, forKey: .totalPages)
        currentStreak = try c.decodeIfPresent(Double.self, forKey: .currentStreak)
        longestStreak = try c.decodeIfPresent(Double.self, forKey: .longestStreak)
        genresRead = try c.decodeIfPresent(Double.self, forKey: .genresRead)
        sessionsLogged = try c.decodeIfPresent(Double.self, forKey: .sessionsLogged)
        quotesSaved = try c.decodeIfPresent(Double.self, forKey: .quotesSaved)
        booksReread = try c.decodeIfPresent(Double.self, forKey: .booksReread)
        nudgesSent = try c.decodeIfPresent(Double.self, forKey: .nudgesSent)
        nudgesTaken = try c.decodeIfPresent(Double.self, forKey: .nudgesTaken)
        commentsPosted = try c.decodeIfPresent(Double.self, forKey: .commentsPosted)
        minutesRead = try c.decodeIfPresent(Double.self, forKey: .minutesRead)
        ratingsGiven = try c.decodeIfPresent(Double.self, forKey: .ratingsGiven)
        authorsRead = try c.decodeIfPresent(Double.self, forKey: .authorsRead)
        recentActivity = try c.decodeIfPresent([BMActivityDay].self, forKey: .recentActivity) ?? []
        currentlyReading = try c.decodeIfPresent([BMReadingRow].self, forKey: .currentlyReading) ?? []
    }
}

/// The other reader as the partner read names them.
struct BMPartnerInfo: Decodable, Hashable {
    var id: String?
    var name: String
    var level: Int?
    var xp: Double?
}

/// One row of the partner's shelf — their shared fields plus a percent,
/// never their review.
struct BMPartnerBook: Decodable, Identifiable, Hashable {
    var id: String
    var bookId: String?
    var status: String?
    var currentPage: Double?
    var format: String?
    var rating: Int?
    var title: String?
    var author: String?
    var coverUrl: String?
    var totalPages: Int?
    var publishedYear: Int?
    var openLibraryId: String?
    var isbn: String?
    var percent: Double?
    var finishDate: String?
    var updatedAt: String?
    var readCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, format, rating, title, author, percent, isbn
        case bookId = "book_id"
        case currentPage = "current_page"
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
        case publishedYear = "published_year"
        case openLibraryId = "open_library_id"
        case finishDate = "finish_date"
        case updatedAt = "updated_at"
        case readCount = "read_count"
    }
}

/// The other reader's shelf, their year and their numbers.
struct BMPartnerShelf: Decodable {
    var partner: BMPartnerInfo?
    var year: Int?
    var booksThisYear: Int?
    var pagesThisYear: Double?
    var stats: BMStatBlock?
    var books: [BMPartnerBook]
}

/// One book in the year's wrap — which field names it carries depends on
/// which list it came from.
struct BMWrappedBook: Decodable, Hashable {
    var title: String?
    var author: String?
    var totalPages: Int?
    var days: Double?
    var durationMinutes: Int?
    var startDate: String?
    var finishDate: String?

    enum CodingKeys: String, CodingKey {
        case title, author, days
        case totalPages = "total_pages"
        case durationMinutes = "duration_minutes"
        case startDate = "start_date"
        case finishDate = "finish_date"
    }
}

/// A month of the year, for the wrap's activity chart.
struct BMWrappedMonth: Decodable, Hashable {
    var month: String
    var sessions: Int?
    var pages: Double?
}

struct BMWrapped: Decodable {
    var year: Int
    var booksRead: Int
    var pagesRead: Double
    var sessionsCount: Int
    var topGenre: String?
    var longestBook: BMWrappedBook?
    var fastestBook: BMWrappedBook?
    var longestSession: BMWrappedBook?
    var firstBook: BMWrappedBook?
    var lastBook: BMWrappedBook?
    var monthlyActivity: [BMWrappedMonth]
    var bestDay: String?
}

/// A book the other reader finished and liked that you do not have.
struct BMPartnerPick: Decodable, Hashable {
    var openLibraryId: String?
    var title: String?
    var author: String?
    var coverUrl: String?
    var totalPages: Int?
    var publishedYear: Int?
    var isbn: String?
    var genres: [String]?
    var rating: Int?

    enum CodingKeys: String, CodingKey {
        case title, author, genres, rating, isbn
        case openLibraryId = "open_library_id"
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
        case publishedYear = "published_year"
    }
}

/// What to read next — taste lanes the app turns into searches itself.
struct BMRecommendations: Decodable {
    var authors: [String]
    var subjects: [String]
    var partner: BMPartnerInfo?
    var partnerPicks: [BMPartnerPick]
}

// MARK: - Series

/// A named run the bridge lists, with how far the reader has got inside it.
struct BMSeries: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var author: String?
    /// How long the run is meant to be, when the catalogue knows.
    var totalBooks: Int?
    /// Filed books, read books and owned books — the rollup's counts.
    var totalInSeries: Int?
    var booksRead: Int?
    var booksOwned: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, author
        case totalBooks = "total_books"
        case totalInSeries = "total_in_series"
        case booksRead = "books_read"
        case booksOwned = "books_owned"
    }
}

/// One book filed in a run — the catalogue row plus the caller's mark on it.
struct BMSeriesBook: Decodable, Identifiable, Hashable {
    var id: String
    var title: String?
    var author: String?
    var coverUrl: String?
    var totalPages: Int?
    var publishedYear: Int?
    var position: Int?
    /// The caller's shelf state on it — nil when the book is not theirs.
    var status: String?
    var userBookId: String?
    var currentPage: Double?
    var rating: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, author, position, status, rating
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
        case publishedYear = "published_year"
        case userBookId = "user_book_id"
        case currentPage = "current_page"
    }
}

struct BMSeriesDetail: Decodable {
    var series: BMSeries?
    var books: [BMSeriesBook]
}

struct BMSeriesReply: Decodable { var series: [BMSeries] }

// MARK: - Up next

/// One row of the queue — a shelf pin plus just enough to draw it.
struct BMUpNextBook: Decodable, Identifiable, Hashable {
    var id: String
    var status: String?
    var upNext: Int?
    var format: String?
    var title: String?
    var author: String?
    var coverUrl: String?
    var totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, format, title, author
        case upNext = "up_next"
        case coverUrl = "cover_url"
        case totalPages = "total_pages"
    }
}

struct BMUpNextReply: Decodable { var books: [BMUpNextBook] }

// MARK: - Goodreads import

/// One parsed CSV row — the phone turns the export into these, and the file
/// itself never leaves the device.
struct BMImportRow: Encodable {
    var title: String
    var author: String?
    var goodreadsId: String?
    var isbn: String?
    var totalPages: Int?
    var publishedYear: Int?
    var status: String
    var rating: Int?
    var review: String?
    var startDate: String?
    var finishDate: String?
    var readCount: Int?

    enum CodingKeys: String, CodingKey {
        case title, author, isbn, status, rating, review
        case goodreadsId = "goodreads_id"
        case totalPages = "total_pages"
        case publishedYear = "published_year"
        case startDate = "start_date"
        case finishDate = "finish_date"
        case readCount = "read_count"
    }
}

/// What `import` answers — a dry run's counts or the real write's tally.
struct BMImportReply: Decodable {
    var preview: Bool?
    var total: Int?
    var alreadyHave: Int?
    var willAdd: Int?
    var byStatus: [String: Int]?
    var imported: Int?
    var duplicates: Int?
    var newAchievements: [BMAchievement]?
}
