import Foundation
import Security

/// The reader's Hardcover API token (hardcover.app/account/api), kept in this iPhone's Keychain — never in the build,
/// never sent anywhere but Hardcover. Without one, Hardcover is simply not asked.
enum HardcoverVault {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.possiblypengu.pageturner.hardcover",
        kSecAttrAccount as String: "api-token",
    ]

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        remove()
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}

enum HardcoverClient {
    /// The token in use: the reader's own (Settings), else the one the build carried in its Info.plist — put there by
    /// the release build from a repository secret, blank in a build made without it. A build setting that was never
    /// filled stays the literal "$(HARDCOVER_API)", which is no token.
    static var authorization: String? {
        if let mine = HardcoverVault.read().flatMap(HardcoverCore.authorization) { return mine }
        let built = Bundle.main.object(forInfoDictionaryKey: "HardcoverToken") as? String ?? ""
        return built.contains("$(") ? nil : HardcoverCore.authorization(built)
    }

    static var hasToken: Bool { authorization != nil }
    /// Whether the reader has put in a token of their own.
    static var hasOwnToken: Bool { HardcoverVault.read().flatMap(HardcoverCore.authorization) != nil }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    /// Hits for a free-text query (a title and author, or an ISBN). Empty without a token, or on any failure.
    static func search(_ query: String) async -> [HardcoverHit] {
        guard !query.isEmpty,
              let auth = authorization,
              let url = URL(string: HardcoverCore.endpoint),
              let body = HardcoverCore.body(query: query)
        else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return HardcoverCore.parse(data)
    }

    /// Settings' "Test": nil when the token works, else a sentence saying what is wrong.
    static func test() async -> String? {
        guard let auth = authorization else { return "No token saved." }
        guard let url = URL(string: HardcoverCore.endpoint),
              let body = HardcoverCore.body(query: "The Hobbit", perPage: 1)
        else { return "Could not build the request." }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: req) else { return "Could not reach Hardcover." }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return "Hardcover refused the token." }
        guard code == 200 else { return "Hardcover answered \(code)." }
        return HardcoverCore.parse(data).isEmpty ? "The token was not accepted." : nil
    }
}
