import CommonCrypto
import CryptoKit
import Foundation

/// Quest Log's cipher, the one in its chat.js and BookMaster's secretChat.ts: PBKDF2 (SHA-256, 100,000 rounds,
/// a fixed salt) over the passphrase makes an AES-GCM-256 key; each message gets a fresh 12-byte IV; the
/// ciphertext is sealed text then the 16-byte tag, in base64, as WebCrypto writes it. A message made by any
/// of the three opens in the others, so nothing here may drift: `selfTest` holds two messages made by the
/// web's recipe (Node) and the key it makes, and the simulator run fails if this cannot open them.
enum BMQuestLogCrypto {
    /// The key a passphrase makes — the same one on every device that knows it. Slow on purpose (100,000
    /// rounds): call it off the main thread. Nil for an empty passphrase.
    static func deriveKey(_ passphrase: String) -> SymmetricKey? {
        guard !passphrase.isEmpty else { return nil }
        let salt = Array(BMQuestLog.salt.utf8)
        var derived = [UInt8](repeating: 0, count: BMQuestLog.keyBytes)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(BMQuestLog.iterations),
            &derived, derived.count)
        return status == Int32(kCCSuccess) ? SymmetricKey(data: derived) : nil
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
