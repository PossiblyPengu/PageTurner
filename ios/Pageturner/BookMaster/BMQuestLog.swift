import Foundation

/// Quest Log's private chat, apart from any screen and from the cryptography: what a stored message is,
/// how it is opened and laid out, what may be sent. Pure, so it can be checked off-device;
/// `BMQuestLogCrypto` is the cipher and `BMQuestLogChat` the connection.
///
/// Quest Log keeps this conversation encrypted end to end — its server holds ciphertext, never the key —
/// and Pageturner keeps to that: the words are opened on this iPhone. The passphrase makes two keys, each by
/// PBKDF2 with a salt of its own: the chat's encryption key, which stays here, and the sign-in token, which
/// is all Quest Log (and BookMaster's same-address forward) is ever shown, as the bearer. Nothing that opens
/// a message can be made from the token, and the passphrase itself is neither sent nor kept.
/// The recipe is the one in Quest Log's chat.js and utils.js and BookMaster's secretChat.ts, so a message
/// written in any of the three opens in the others, and a token from any of them is accepted.
enum BMQuestLog {
    /// Where Quest Log's chat endpoint is served, on BookMaster's address (the forward to Quest Log's own deployment).
    static let path = "/quest-log/api/chat"
    /// The chat key a passphrase makes: PBKDF2 (SHA-256) over it with this salt, AES-GCM-256 with it.
    static let salt = "quest-log-chat-salt-v1"
    /// The sign-in token it makes, in hex — what the server's APP_AUTH_TOKEN holds: the same PBKDF2 with a salt of its own.
    static let authSalt = "quest-log-auth-v1"
    static let iterations = 100_000
    static let keyBytes = 32
    static let ivBytes = 12
    static let tagBytes = 16
    /// One message, in characters (UTF-16 units, as the server counts): the same limit as the shared room.
    static let maxLength = BMChat.maxLength
    /// How often a room on screen asks again.
    static let pollSeconds: UInt64 = 5

    /// The two parts Quest Log's story gives its players. A device keeps one.
    enum Role: String, CaseIterable, Identifiable {
        case giver, adventurer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .giver: return "The giver"
            case .adventurer: return "The adventurer"
            }
        }

        var other: Role { self == .giver ? .adventurer : .giver }
    }

    /// What Quest Log's endpoint stores for each message. Entries that cannot be read as this are skipped.
    struct Raw: Decodable, Equatable {
        var id: String
        var role: String
        var ciphertext: String
        var iv: String
        /// Milliseconds since 1970, as Quest Log stamps them.
        var ts: Double

        enum CodingKeys: String, CodingKey { case id, role, ciphertext, iv, ts }

        init(id: String, role: String, ciphertext: String, iv: String, ts: Double) {
            self.id = id
            self.role = role
            self.ciphertext = ciphertext
            self.iv = iv
            self.ts = ts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // an id is a string, or — from older rooms — a number
            if let text = try? c.decode(String.self, forKey: .id) {
                id = text
            } else if let number = try? c.decode(Double.self, forKey: .id), number.isFinite {
                id = String(Int64(number))
            } else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "an entry with no id")
            }
            role = (try? c.decode(String.self, forKey: .role)) ?? ""
            ciphertext = try c.decode(String.self, forKey: .ciphertext)
            iv = try c.decode(String.self, forKey: .iv)
            ts = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        }
    }

    /// A message, opened. `failed`: this passphrase does not open it.
    struct Entry: Identifiable, Equatable {
        var id: String
        var role: Role
        var text: String
        /// Milliseconds since 1970.
        var at: Double
        var failed: Bool

        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    /// The stored entries out of the endpoint's answer, oldest first; one that is malformed is left out, not
    /// the whole room.
    static func decode(_ data: Data) -> [Raw] {
        struct Lossy: Decodable {
            var raw: Raw?
            init(from decoder: Decoder) throws { raw = try? Raw(from: decoder) }
        }
        guard let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return all.compactMap(\.raw)
    }

    /// One stored entry, opened with `opener` (ciphertext and iv, in base64, to the plain text or nil). Nil
    /// for a role Quest Log does not have.
    static func open(_ raw: Raw, opener: (_ ciphertext: String, _ iv: String) -> String?) -> Entry? {
        guard let role = Role(rawValue: raw.role) else { return nil }
        guard let plain = opener(raw.ciphertext, raw.iv) else {
            return Entry(id: raw.id, role: role, text: "🔒", at: raw.ts, failed: true)
        }
        return Entry(id: raw.id, role: role, text: unwrap(plain), at: raw.ts, failed: false)
    }

    /// Quest Log wraps some messages as `{"text": …}`; anything else that is plain text stands as it comes. (An
    /// object with no text, or a list, is empty — what the web page makes of it too.)
    static func unwrap(_ plain: String) -> String {
        guard let data = plain.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return plain }
        if let object = parsed as? [String: Any] { return (object["text"] as? String) ?? "" }
        if parsed is [Any] { return "" }
        return plain
    }

    /// Each id once, in the order first seen (a re-post that raced its original is not shown twice).
    static func once(_ raws: [Raw]) -> [Raw] {
        var seen = Set<String>()
        return raws.filter { seen.insert($0.id).inserted }
    }

    /// An id Quest Log accepts (6–40 letters, digits, `_` or `-`), unique enough that a message sent again after
    /// a lost answer is recognised and not stored twice.
    static func newID(now: Date = Date(), randomness: () -> UInt64 = { UInt64.random(in: 0 ..< UInt64.max) }) -> String {
        let stamp = String(UInt64(max(0, now.timeIntervalSince1970 * 1000)), radix: 36)
        let tail = String(randomness() % 2_176_782_336, radix: 36)   // 36^6
        return "m" + stamp + String(repeating: "0", count: max(0, 6 - tail.count)) + tail
    }

    /// Whether this is an id the endpoint takes.
    static func isValidID(_ id: String) -> Bool {
        (6 ... 40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// One message in the thread, with what the layout adds: a day label on the first of each day, the name on the
    /// first of a burst, the time on its last.
    struct Row: Identifiable, Equatable {
        var entry: Entry
        var day: String?
        var head: Bool
        var tail: Bool
        var id: String { entry.id }
    }

    /// The same layout as the shared room's (`BMChat.rows`): its rule for a burst and for a day.
    static func rows(
        _ entries: [Entry], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> [Row] {
        // stand-ins for the shared room's messages, one per entry in the same order: the speaker is the role
        let stand = entries.enumerated().map { index, entry in
            BMChatMessage(id: index, userId: entry.role.rawValue, name: "", body: "", app: "quest-log", at: entry.at)
        }
        return zip(entries, BMChat.rows(stand, now: now, calendar: calendar, locale: locale)).map { entry, row in
            Row(entry: entry, day: row.day, head: row.head, tail: row.tail)
        }
    }

    /// What goes up: the draft trimmed, or nil when it is blank or over the limit.
    static func sendable(_ draft: String) -> String? { BMChat.sendable(draft) }

    /// What to tell the reader when a request fails.
    enum Failure: Error, Equatable {
        /// 401: not the passphrase (or no longer: it was changed in Quest Log).
        case wrongPassphrase
        /// 403: that role belongs to another device.
        case roleTaken
        /// 429: too many wrong passphrases from here lately (10 in 15 minutes); try again later.
        case tooManyGuesses
        /// Anything else Quest Log answered.
        case server(Int)
        /// No answer at all.
        case unreachable
    }

    static func explain(_ failure: Failure, sending: Bool = false) -> String {
        switch failure {
        case .wrongPassphrase: return "That is not the Quest Log passphrase."
        case .roleTaken: return "Quest Log says that role belongs to another device."
        case .tooManyGuesses: return "Too many wrong passphrases. Try again in a little while."
        case let .server(code): return "Quest Log did not answer (\(code))."
        case .unreachable: return sending ? "That did not send. Try again." : "Could not reach Quest Log. Nothing is lost; try again in a moment."
        }
    }

    /// The failure a status code stands for, or nil when it is a success.
    static func failure(forStatus status: Int) -> Failure? {
        switch status {
        case 200 ..< 300: return nil
        case 401: return .wrongPassphrase
        case 403: return .roleTaken
        case 429: return .tooManyGuesses
        default: return .server(status)
        }
    }
}
