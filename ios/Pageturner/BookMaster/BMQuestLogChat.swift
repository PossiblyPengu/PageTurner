import CryptoKit
import Foundation
import Observation
import Security

/// Quest Log's private room, opened on this iPhone. It talks to Quest Log's chat endpoint on BookMaster's
/// address (which forwards to Quest Log's own deployment) with the sign-in token the passphrase makes as the
/// bearer — what Quest Log's own pages send — and opens and seals every message here, so neither Quest Log's
/// server nor BookMaster nor anything on the way ever holds the words or what opens them.
///
/// The passphrase is used once, to make the two keys, and is neither sent nor kept. What is kept is the keys —
/// in memory, and in this iPhone's Keychain (this device only, while it is unlocked) when the reader leaves
/// "Keep it unlocked on this iPhone" on, so the passphrase need not be typed again; locking the room,
/// unlinking BookMaster, or signing out of the web apps erases them.
@Observable
@MainActor
final class BMQuestLogChat {
    static let shared = BMQuestLogChat()

    /// The room has been opened with a passphrase Quest Log accepted (or the keys it made, remembered).
    private(set) var unlocked = false
    /// The first answer has been read — until then an empty list would look like a wiped history.
    private(set) var ready = false
    /// The messages, oldest first.
    private(set) var entries: [BMQuestLog.Entry] = []
    /// Why the room could not be loaded; shown in its place while nothing has loaded.
    private(set) var loadError: String?
    /// Why a send or a take-back failed; it stays until the next try.
    var actionError: String?
    /// Counts the messages sent, so a screen can scroll to its own.
    private(set) var sent = 0
    /// The passphrase was changed in Quest Log: said on the lock screen after the room locks itself.
    private(set) var lockNotice: String?

    /// The sign-in token (the bearer) and the chat key, made from the passphrase.
    private var credentials: BMQuestLogCrypto.Credentials?
    private var key: SymmetricKey?
    /// Messages already opened, so a poll opens only what is new.
    private var opened: [String: BMQuestLog.Entry] = [:]
    /// Messages sent that the room's list does not show yet — kept in view until it does.
    private var pending: [String: BMQuestLog.Entry] = [:]
    private var refreshing = false
    private var loadedFor: String?
    /// The simulator run's room: it asks no one, so nothing it shows can be locked by a real answer.
    private var offline = false
    private let defaults = UserDefaults.standard

    // MARK: The account

    private var username: String? { BookMaster.shared.user?.username }

    /// Pick up the remembered keys for the linked reader, once for each account.
    func loadIfNeeded() {
        let current = username
        guard current != loadedFor else { return }
        loadedFor = current
        wipeMemory()
        guard let current, let saved = BMQuestLogVault.read(account: current) else { return }
        if let data = saved.data(using: .utf8), let keys = try? JSONDecoder().decode(BMQuestLogCrypto.Credentials.self, from: data) {
            // trusted until Quest Log says otherwise: the first poll answers 401 to a passphrase that was changed
            Task { await open(with: keys, remember: true, verify: false) }
        } else {
            // kept by an earlier build as the passphrase itself: made into keys now, and only they are kept
            Task { await unlock(saved, remember: true) }
        }
    }

    // MARK: Unlocking

    /// Open the room with a passphrase: made into the two keys, and Quest Log asked whether its token is the
    /// right one (a wrong passphrase is a 401). Nothing is kept unless Quest Log accepts it, and the passphrase
    /// itself never is. Returns why not, or nil.
    @discardableResult
    func unlock(_ passphrase: String, remember: Bool) async -> String? {
        guard let keys = await Self.makeKeys(passphrase) else { return "That is not the Quest Log passphrase." }
        return await open(with: keys, remember: remember, verify: true)
    }

    @discardableResult
    private func open(with keys: BMQuestLogCrypto.Credentials, remember: Bool, verify: Bool) async -> String? {
        if verify {
            do {
                _ = try await call("GET", token: keys.token)
            } catch let failure as BMQuestLog.Failure {
                return BMQuestLog.explain(failure)
            } catch {
                return BMQuestLog.explain(.unreachable)
            }
        }
        credentials = keys
        key = keys.symmetricKey
        lockNotice = nil
        unlocked = true
        if let username {
            if remember, let data = try? JSONEncoder().encode(keys), let text = String(data: data, encoding: .utf8) {
                BMQuestLogVault.write(text, account: username)
            } else {
                BMQuestLogVault.remove(account: username)
            }
        }
        await refresh()
        return nil
    }

    /// The two keys a passphrase makes, off the main thread: two hundred thousand rounds of hashing.
    private nonisolated static func makeKeys(_ passphrase: String) async -> BMQuestLogCrypto.Credentials? {
        await Task.detached(priority: .userInitiated) { BMQuestLogCrypto.credentials(for: passphrase) }.value
    }

    /// Close the room: the keys and every message are forgotten, here and in the Keychain.
    func lock(notice: String? = nil) {
        if let username { BMQuestLogVault.remove(account: username) }
        wipeMemory()
        lockNotice = notice
    }

    /// Unlinked, or signed out of the web apps: the room belongs to the reader that went away.
    func reset() {
        BMQuestLogVault.removeAll()
        wipeMemory()
        loadedFor = nil
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(Self.roleKeyPrefix) {
            defaults.removeObject(forKey: name)
        }
    }

    private func wipeMemory() {
        credentials = nil
        key = nil
        unlocked = false
        ready = false
        entries = []
        opened = [:]
        pending = [:]
        loadError = nil
        actionError = nil
        lockNotice = nil
    }

    // MARK: Which part is yours

    private static let roleKeyPrefix = "ql-role-"

    /// Quest Log's two parts, as BookMaster says this reader plays one (its `questLogRole`); otherwise the one
    /// they chose here. Nil until one is known.
    func role(serverSays said: String?) -> BMQuestLog.Role? {
        if let said, let role = BMQuestLog.Role(rawValue: said) { return role }
        guard let username, let raw = defaults.string(forKey: Self.roleKeyPrefix + username) else { return nil }
        return BMQuestLog.Role(rawValue: raw)
    }

    func choose(_ role: BMQuestLog.Role?) {
        guard let username else { return }
        if let role { defaults.set(role.rawValue, forKey: Self.roleKeyPrefix + username) }
        else { defaults.removeObject(forKey: Self.roleKeyPrefix + username) }
    }

    // MARK: Reading

    /// Look again every few seconds while the room is on screen.
    func poll() async {
        while !Task.isCancelled, unlocked {
            await refresh()
            try? await Task.sleep(nanoseconds: BMQuestLog.pollSeconds * 1_000_000_000)
        }
    }

    func refresh() async {
        // one at a time: two in flight can land out of order, and the older would overwrite the newer
        guard unlocked, !offline, !refreshing, let token = credentials?.token, let key else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await call("GET", token: token)
            // locked, or other keys in, while this was out
            guard unlocked, credentials?.token == token else { return }
            var list: [BMQuestLog.Entry] = []
            let stored = BMQuestLog.once(BMQuestLog.decode(data))
            for raw in stored {
                if let hit = opened[raw.id] {
                    list.append(hit)
                } else if let entry = BMQuestLogCrypto.open(raw, with: key) {
                    if !entry.failed { opened[raw.id] = entry }
                    list.append(entry)
                }
            }
            // what was sent and is not listed yet stays where it was put; what is listed is the room's now
            let listed = Set(stored.map(\.id))
            pending = pending.filter { !listed.contains($0.key) }
            entries = list + pending.values.sorted { $0.at < $1.at }
            ready = true
            loadError = nil
        } catch BMQuestLog.Failure.wrongPassphrase {
            lock(notice: "The Quest Log passphrase has changed. Enter the new one.")
        } catch {
            guard !Task.isCancelled else { return }
            if !ready { loadError = BMQuestLog.explain((error as? BMQuestLog.Failure) ?? .unreachable) }
        }
    }

    // MARK: Writing

    /// Seal `text` and send it as `role`. False (with `actionError` said) when it did not go.
    func send(_ text: String, as role: BMQuestLog.Role) async -> Bool {
        if offline {
            let now = Date().timeIntervalSince1970 * 1000
            entries.append(BMQuestLog.Entry(id: BMQuestLog.newID(), role: role, text: text, at: now, failed: false))
            sent += 1
            return true
        }
        guard unlocked, let token = credentials?.token, let key, let sealed = BMQuestLogCrypto.seal(key, text) else {
            actionError = BMQuestLog.explain(.unreachable, sending: true)
            return false
        }
        actionError = nil
        let id = BMQuestLog.newID()
        let body: [String: String] = ["id": id, "ciphertext": sealed.ciphertext, "iv": sealed.iv, "role": role.rawValue]
        do {
            guard let json = try? JSONSerialization.data(withJSONObject: body) else { throw BMQuestLog.Failure.unreachable }
            _ = try await call("POST", body: json, token: token)
        } catch BMQuestLog.Failure.wrongPassphrase {
            lock(notice: "The Quest Log passphrase has changed. Enter the new one.")
            return false
        } catch {
            actionError = BMQuestLog.explain((error as? BMQuestLog.Failure) ?? .unreachable, sending: true)
            return false
        }
        let entry = BMQuestLog.Entry(
            id: id, role: role, text: text, at: (Date().timeIntervalSince1970 * 1000).rounded(), failed: false)
        opened[id] = entry
        pending[id] = entry
        entries.append(entry)
        sent += 1
        await refresh()
        return true
    }

    /// Take back one of your own messages.
    func remove(_ entry: BMQuestLog.Entry) async {
        guard unlocked, !offline, let token = credentials?.token else { return }
        actionError = nil
        do {
            _ = try await call("DELETE", id: entry.id, token: token)
        } catch BMQuestLog.Failure.wrongPassphrase {
            lock(notice: "The Quest Log passphrase has changed. Enter the new one.")
            return
        } catch {
            actionError = "Could not delete that."
            return
        }
        opened[entry.id] = nil
        pending[entry.id] = nil
        entries.removeAll { $0.id == entry.id }
        await refresh()
    }

    // MARK: The wire

    /// One request to Quest Log's chat endpoint. Throws a `BMQuestLog.Failure`.
    private func call(_ method: String, id: String? = nil, body: Data? = nil, token: String) async throws -> Data {
        guard var parts = URLComponents(string: "https://\(BMLinkURL.bookMasterHost)\(BMQuestLog.path)") else {
            throw BMQuestLog.Failure.unreachable
        }
        if let id { parts.queryItems = [URLQueryItem(name: "id", value: id)] }
        guard let url = parts.url else { throw BMQuestLog.Failure.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BMQuestLog.Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = BMQuestLog.failure(forStatus: status) { throw failure }
        return data
    }

    #if DEBUG
    /// The simulator run's photograph: an opened room with a few messages, and no network.
    func debugFixture() {
        let now = Date().timeIntervalSince1970 * 1000
        func entry(_ id: String, _ role: BMQuestLog.Role, _ text: String, _ minutesAgo: Double, failed: Bool = false) -> BMQuestLog.Entry {
            BMQuestLog.Entry(id: id, role: role, text: text, at: now - minutesAgo * 60_000, failed: failed)
        }
        wipeMemory()
        loadedFor = username          // the screen's first look must not wipe it
        offline = true
        credentials = BMQuestLogCrypto.Credentials(token: "debug", key: Data(repeating: 7, count: 32))
        key = SymmetricKey(size: .bits256)
        unlocked = true
        ready = true
        entries = [
            entry("a1", .adventurer, "The map is done. It leads under the old mill.", 190),
            entry("a2", .adventurer, "Bring a lantern.", 189),
            entry("g1", .giver, "Then tonight we go. Quest accepted.", 160),
            entry("g2", .giver, "I will leave the key under the third stone.", 159),
            entry("a3", .adventurer, "🔒", 40, failed: true),
            entry("a4", .adventurer, "Nothing under the third stone but a note: “look up”.", 12),
        ]
        choose(.giver)
    }
    #endif
}

/// The keys the passphrase made (as JSON), kept in this iPhone's Keychain for the reader who asked for it: this device
/// only, and only while it is unlocked. (An earlier build kept the passphrase itself in the same place; it is read
/// once and replaced.)
enum BMQuestLogVault {
    private static let service = "io.github.possiblypengu.pageturner.questlog"

    private static func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func read(account: String) -> String? {
        var item: CFTypeRef?
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ secret: String, account: String) {
        remove(account: account)
        var add = query(account)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// Every account's: unlinking leaves nothing behind.
    static func removeAll() {
        SecItemDelete(query(nil) as CFDictionary)
    }
}
