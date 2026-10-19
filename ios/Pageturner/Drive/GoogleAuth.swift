import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

/// Something that went wrong with Drive, in words for the reader.
struct DriveError: LocalizedError {
    var message: String
    var errorDescription: String? { message }

    static let notSignedIn = DriveError(message: "Sign in to Google Drive first (Settings → Google Drive).")
    static let offline = DriveError(message: "Couldn’t reach Google Drive. Check the connection and try again.")
}

/// Signing in to Google, so Pageturner can read the Drive files the reader picks and keep its own backups there.
///
/// OAuth for an installed app: the reader signs in on Google's own page (a system web sheet, which can use the
/// Google login Safari already has), with PKCE so no client secret exists to be kept, and Google sends them back
/// on a scheme made from the client ID. What comes back is kept as little as possible: the refresh token, in the
/// Keychain (this device only), and an access token in memory for the hour it lasts.
///
/// The client ID is the reader's own — an *iOS* OAuth client in their Google Cloud project, pasted in Settings →
/// Google Drive — because Google issues tokens only to a registered client. A client ID is a public identifier,
/// not a secret. (`builtInClientID` is where one could be compiled in, so a build can ship ready.)
@Observable
@MainActor
final class GoogleAuth {
    static let shared = GoogleAuth()

    /// A client ID built into the app; blank until one is. The reader's own (below) wins.
    static let builtInClientID = ""
    private static let clientKey = "drive-client-id"
    private static let accountKey = "drive-account"

    /// The reader's iOS client ID, as pasted. Kept on this iPhone.
    var clientID: String {
        get {
            access(keyPath: \.clientID)
            let stored = UserDefaults.standard.string(forKey: Self.clientKey) ?? ""
            return stored.isEmpty ? Self.builtInClientID : stored
        }
        set {
            withMutation(keyPath: \.clientID) {
                UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientKey)
            }
        }
    }
    /// Signed in: a refresh token is held.
    private(set) var signedIn: Bool
    /// "name@gmail.com", as Google says it, once known.
    private(set) var account: String?
    private(set) var busy = false
    /// Why the last sign-in failed, until the next try.
    private(set) var error: String?

    private var held: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    private let presenter = AuthPresenter()
    private var web: ASWebAuthenticationSession?
    private let session: URLSession

    private init() {
        signedIn = DriveVault.read() != nil
        account = UserDefaults.standard.string(forKey: Self.accountKey)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    /// A client ID that looks right, so a sign-in can be tried.
    var isConfigured: Bool { GoogleDrive.isClientID(clientID) }

    // MARK: Signing in and out

    func signIn() async {
        guard !busy else { return }
        guard isConfigured else {
            error = "Paste your iOS client ID first (it ends in .apps.googleusercontent.com)."
            return
        }
        busy = true
        error = nil
        defer { busy = false }

        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = Self.randomToken(bytes: 48)
        let challenge = GoogleDrive.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomToken(bytes: 16)
        guard let url = GoogleDrive.authURL(clientID: id, challenge: challenge, state: state),
              let scheme = GoogleDrive.redirectScheme(clientID: id)
        else {
            error = "That client ID can’t be used."
            return
        }
        do {
            let callback = try await authenticate(url: url, scheme: scheme)
            switch GoogleDrive.code(fromCallback: callback, expectedState: state) {
            case let .success(code):
                try await finish(code: code, verifier: verifier, clientID: id)
            case let .failure(failure):
                switch failure {
                case .cancelled: break
                case .denied: error = GoogleDrive.explainSignIn(errorCode: "access_denied")
                case .mismatch: error = "That sign-in did not match the one that was started. Try again."
                case let .failed(code): error = GoogleDrive.explainSignIn(errorCode: code)
                }
            }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            // the reader closed the sheet: nothing to say
        } catch GoogleDrive.SignInFailure.cancelled {
            // likewise
        } catch {
            self.error = (error as? DriveError)?.message ?? error.localizedDescription
        }
    }

    /// Forget the sign-in here, and ask Google to drop it too.
    func signOut() async {
        let token = DriveVault.read()
        DriveVault.remove()
        held = nil
        refreshing = nil
        signedIn = false
        account = nil
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        if let token, let url = URL(string: GoogleDrive.revokeEndpoint) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GoogleDrive.form([("token", token)])
            _ = try? await session.data(for: request)   // best effort: it is forgotten here either way
        }
    }

    // MARK: Tokens

    /// An access token that works now: the one held, or a new one from the refresh token.
    func accessToken() async throws -> String {
        if let held, GoogleDrive.isFresh(expires: held.expires, now: Date()) { return held.token }
        if let refreshing { return try await refreshing.value }
        guard let refresh = DriveVault.read() else {
            signedIn = false
            throw DriveError.notSignedIn
        }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = Task { try await renew(refresh: refresh, clientID: id) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// The token was refused: ask for a new one next time.
    func discardAccessToken() { held = nil }

    private func renew(refresh: String, clientID: String) async throws -> String {
        let (data, status) = try await post(GoogleDrive.refresh(token: refresh, clientID: clientID))
        guard (200 ..< 300).contains(status), let reply = try? JSONDecoder().decode(GoogleDrive.TokenReply.self, from: data) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            if code == "invalid_grant" {
                // revoked, or run out: nothing held is any use any more
                DriveVault.remove()
                signedIn = false
            }
            throw DriveError(message: GoogleDrive.explainSignIn(errorCode: code))
        }
        held = (reply.accessToken, Date().addingTimeInterval(reply.expiresIn))
        return reply.accessToken
    }

    private func finish(code: String, verifier: String, clientID: String) async throws {
        guard let body = GoogleDrive.codeExchange(code: code, verifier: verifier, clientID: clientID) else {
            throw DriveError(message: "That client ID can’t be used.")
        }
        let (data, status) = try await post(body)
        guard (200 ..< 300).contains(status), let reply = try? JSONDecoder().decode(GoogleDrive.TokenReply.self, from: data) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw DriveError(message: GoogleDrive.explainSignIn(errorCode: code))
        }
        guard GoogleDrive.grantedAll(reply.scope) else {
            // the reader unticked a permission on Google's page
            throw DriveError(message: "Google did not give every permission asked for. Sign in again and leave them all ticked: Pageturner reads the files you pick and writes only its own backups.")
        }
        guard let refresh = reply.refreshToken else {
            throw DriveError(message: "Google did not keep the sign-in. Remove Pageturner at myaccount.google.com/permissions and sign in again.")
        }
        DriveVault.write(refresh)
        held = (reply.accessToken, Date().addingTimeInterval(reply.expiresIn))
        signedIn = true
        await loadAccount()
    }

    /// Who is signed in, for the settings page.
    func loadAccount() async {
        guard signedIn, let token = try? await accessToken() else { return }
        var request = URLRequest(url: GoogleDrive.aboutURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let user = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["user"] as? [String: Any]
        else { return }
        let name = (user["emailAddress"] as? String) ?? (user["displayName"] as? String)
        account = name
        UserDefaults.standard.set(name, forKey: Self.accountKey)
    }

    // MARK: The wire

    private func post(_ body: Data) async throws -> (Data, Int) {
        guard let url = URL(string: GoogleDrive.tokenEndpoint) else { throw DriveError.offline }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw DriveError.offline
        }
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? GoogleDrive.SignInFailure.cancelled)
                }
            }
            web.presentationContextProvider = presenter
            web.prefersEphemeralWebBrowserSession = false
            self.web = web
            if !web.start() {
                continuation.resume(throwing: DriveError(message: "Couldn’t open Google’s sign-in page."))
            }
        }
    }

    /// Random text that is safe in a URL: a PKCE verifier (43–128 characters) or a state.
    private static func randomToken(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        if status != errSecSuccess { data = Data((0 ..< bytes).map { _ in UInt8.random(in: .min ... .max) }) }
        return GoogleDrive.base64URL(data)
    }
}

/// Where Google's sign-in sheet comes up: over the app's window.
private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }
}

/// The refresh token, kept in this iPhone's Keychain: this device only, and only while it is unlocked.
enum DriveVault {
    private static let service = "io.github.possiblypengu.pageturner.drive"
    private static let account = "refresh-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

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
