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

struct BMPartner: Decodable {
    var name: String
    var online: Bool
    var reading: BMReading?
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
    var nudges: [BMNudge]
    /// Suggestions of yours still out with the other reader.
    var sent: [BMSentNudge]
    var notices: [BMNotice]

    enum CodingKeys: String, CodingKey {
        case partner, nudges, sent, notices
    }

    init(partner: BMPartner?, nudges: [BMNudge], sent: [BMSentNudge], notices: [BMNotice]) {
        self.partner = partner
        self.nudges = nudges
        self.sent = sent
        self.notices = notices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partner = try c.decodeIfPresent(BMPartner.self, forKey: .partner)
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

// MARK: - Overview (stats)

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
}

// MARK: - Series

// MARK: - Up next

// MARK: - Goodreads import
