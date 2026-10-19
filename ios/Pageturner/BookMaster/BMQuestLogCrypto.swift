import CommonCrypto
import CryptoKit
import Foundation

/// Quest Log's cipher, the one in its chat.js and utils.js and BookMaster's secretChat.ts: PBKDF2 (SHA-256, 100,000
/// rounds) over the passphrase makes two keys, each with a salt of its own — an AES-GCM-256 chat key, and a
/// sign-in token (hex) that is all the server is shown. Each message gets a fresh 12-byte IV; the ciphertext
/// is sealed text then the 16-byte tag, in base64, as WebCrypto writes it. A message made by any of the three
/// opens in the others, and a token from any of them is accepted, so nothing here may drift: `selfTest` holds
/// two messages and the keys the web's recipe makes (Node; the same answers Quest Log's own tests check), and
/// the simulator run fails if this cannot reproduce them.
enum BMQuestLogCrypto {
    /// What a passphrase makes, and all that is kept of it: the chat key, which opens messages and never leaves this
    /// iPhone, and the sign-in token Quest Log is shown. Neither opens the other.
    struct Credentials: Codable, Equatable {
        var token: String
        var key: Data

        var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
    }

    /// PBKDF2 (SHA-256, 100,000 rounds) over the passphrase with `salt`. Slow on purpose: call it off the main
    /// thread. Nil for an empty passphrase.
    private static func pbkdf2(_ passphrase: String, salt: String) -> [UInt8]? {
        guard !passphrase.isEmpty else { return nil }
        let salt = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: BMQuestLog.keyBytes)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(BMQuestLog.iterations),
            &derived, derived.count)
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// The key a passphrase makes for the chat — the same one on every device that knows it.
    static func deriveKey(_ passphrase: String) -> SymmetricKey? {
        pbkdf2(passphrase, salt: BMQuestLog.salt).map { SymmetricKey(data: $0) }
    }

    /// The sign-in token a passphrase makes, in lower-case hex: what Quest Log's APP_AUTH_TOKEN holds.
    static func deriveAuthToken(_ passphrase: String) -> String? {
        pbkdf2(passphrase, salt: BMQuestLog.authSalt).map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// Both, from the passphrase.
    static func credentials(for passphrase: String) -> Credentials? {
        guard let token = deriveAuthToken(passphrase), let key = pbkdf2(passphrase, salt: BMQuestLog.salt) else { return nil }
        return Credentials(token: token, key: Data(key))
    }

    /// The text, or nil when this key does not open it.
    static func open(_ key: SymmetricKey, ciphertext: String, iv: String) -> String? {
        guard let sealed = Data(base64Encoded: ciphertext), let nonceBytes = Data(base64Encoded: iv),
              sealed.count >= BMQuestLog.tagBytes, nonceBytes.count == BMQuestLog.ivBytes,
              let nonce = try? AES.GCM.Nonce(data: nonceBytes)
        else { return nil }
        let body = sealed.dropLast(BMQuestLog.tagBytes)
        let tag = sealed.suffix(BMQuestLog.tagBytes)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// The text sealed with a fresh IV: ciphertext and tag together, and the IV, each in base64.
    static func seal(_ key: SymmetricKey, _ text: String) -> (ciphertext: String, iv: String)? {
        let nonce = AES.GCM.Nonce()
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key, nonce: nonce) else { return nil }
        return ((box.ciphertext + box.tag).base64EncodedString(), Data(nonce).base64EncodedString())
    }

    /// An entry opened by `key`.
    static func open(_ raw: BMQuestLog.Raw, with key: SymmetricKey) -> BMQuestLog.Entry? {
        BMQuestLog.open(raw) { ciphertext, iv in open(key, ciphertext: ciphertext, iv: iv) }
    }

    // MARK: Known answers

    /// Made by Node's crypto with the web page's recipe: passphrase "open sesame ✨", its key, and two messages
    /// (one plain, one wrapped as `{"text": …}`). Nil when all agree with this cipher, else what does not.
    static func selfTest() -> String? {
        let passphrase = "open sesame ✨"
        guard let key = deriveKey(passphrase) else { return "no key" }
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        guard hex == "9b86e93e1221e5cb8ee6e54b5514b566a6493daae03fe56eecf6a57c47c6d6eb" else { return "key \(hex)" }
        // the sign-in token: the answers Quest Log's own tests (tests/auth-token.test.mjs) hold
        let token = deriveAuthToken(passphrase)
        guard token == "c2834e97ebc29b53220ada973bc91961897df59fc339b9bc8709c29dbe17e949" else { return "token \(token ?? "nil")" }
        let plainToken = deriveAuthToken("pass")
        guard plainToken == "4926a8ec0a3bc5f3b381a2f8d593648ff025f9f4a0b9944e110f63e4f0bc46ba" else { return "token for pass \(plainToken ?? "nil")" }
        guard let made = credentials(for: passphrase), made.token == token, made.key == key.withUnsafeBytes({ Data($0) }),
              made.token != hex
        else { return "credentials" }
        let plain = open(
            key, ciphertext: "ZS/9RtpCJO3nzvIqcSVGRyn4SVenx7z79Of1WyvOUKQQBllb9lGXyw0sNzJzqP+V0GGa/6Jp6q6SH/6B75U=",
            iv: "AAECAwQFBgcICQoL")
        guard plain == "See you at the tavern, 🍺 — bring the map." else { return "plain opened as \(plain ?? "nil")" }
        let wrapped = open(
            BMQuestLog.Raw(
                id: "kat-wrapped", role: "giver",
                ciphertext: "uDV5WfQD8pCD5Wp+IX6HydjHq6r9FXPDzL15MuKW1jh7Z79ugiTemQ==", iv: "CgsMDQ4PEBESExQV", ts: 1),
            with: key)
        guard wrapped?.text == "Wrapped hello", wrapped?.failed == false else { return "wrapped opened as \(wrapped?.text ?? "nil")" }
        // what this seals, it opens; and not with another passphrase
        guard let sealed = seal(key, "round trip"),
              open(key, ciphertext: sealed.ciphertext, iv: sealed.iv) == "round trip"
        else { return "seal and open do not agree" }
        guard let other = deriveKey("not it"),
              open(other, ciphertext: sealed.ciphertext, iv: sealed.iv) == nil
        else { return "another passphrase opened it" }
        return nil
    }
}
