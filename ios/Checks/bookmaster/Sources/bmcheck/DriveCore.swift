import Foundation

/// Google Drive, apart from any screen and from the network: what a Drive file is, the queries that find books,
/// the sign-in addresses, what is new in a watched folder, which backups to clear away, and what to say when
/// Google answers with an error. Pure, so it can be checked off-device (ios/Checks/bookmaster); `GoogleAuth` signs in,
/// `DriveClient` talks to the API, and `DriveSync`, `DriveBackup` and `DriveBrowserView` use them.
///
/// The app asks for two scopes. `drive.readonly` lets it browse and download what the reader picks (a restricted
/// scope: fine for one's own use, where Google lists the app as unverified). `drive.file` lets it write only
/// what it made itself — the "Pageturner Backups" folder and the zips in it — and nothing else in the Drive.
enum GoogleDrive {
    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    static let readScope = "https://www.googleapis.com/auth/drive.readonly"
    static let fileScope = "https://www.googleapis.com/auth/drive.file"
    static let scopes = [readScope, fileScope]

    static let folderMime = "application/vnd.google-apps.folder"
    static let shortcutMime = "application/vnd.google-apps.shortcut"
    /// Where scheduled backups go, and the only folder the app ever writes to.
    static let backupFolderName = "Pageturner Backups"
    /// The part of a client ID the sign-in redirect is made from.
    static let clientIDSuffix = ".apps.googleusercontent.com"
    /// The iOS OAuth client this build signs in with: Pageturner's, in its maker's Google Cloud project. A client ID is a
    /// public identifier, not a secret. Settings → Google Drive can still be given another one (a reader's own project).
    static let defaultClientID = "79088580141-hddbc474ivueq19gutoq1f426u85j4qf.apps.googleusercontent.com"

    // MARK: Files

    /// One file or folder, as Drive describes it.
    struct File: Decodable, Identifiable, Equatable, Hashable {
        var id: String
        var name: String
        var mimeType: String
        var size: Int64?
        var modifiedTime: Date?
        var md5Checksum: String?
        var shortcutDetails: Shortcut?
        /// In the bin: only asked for when one file is looked at (a listing leaves the bin out).
        var trashed: Bool?

        struct Shortcut: Decodable, Equatable, Hashable {
            var targetId: String
            var targetMimeType: String
        }

        enum CodingKeys: String, CodingKey { case id, name, mimeType, size, modifiedTime, md5Checksum, shortcutDetails, trashed }

        init(
            id: String, name: String, mimeType: String, size: Int64? = nil, modifiedTime: Date? = nil,
            md5Checksum: String? = nil, shortcutDetails: Shortcut? = nil
        ) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.size = size
            self.modifiedTime = modifiedTime
            self.md5Checksum = md5Checksum
            self.shortcutDetails = shortcutDetails
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            mimeType = (try? c.decode(String.self, forKey: .mimeType)) ?? ""
            // Drive sends sizes as strings, in bytes
            if let text = try? c.decode(String.self, forKey: .size) { size = Int64(text) }
            else { size = try? c.decode(Int64.self, forKey: .size) }
            modifiedTime = (try? c.decode(String.self, forKey: .modifiedTime)).flatMap(GoogleDrive.date)
            md5Checksum = try? c.decode(String.self, forKey: .md5Checksum)
            shortcutDetails = try? c.decode(Shortcut.self, forKey: .shortcutDetails)
            trashed = try? c.decode(Bool.self, forKey: .trashed)
        }

        /// A shortcut is what it points at: the same name, the target's id and kind.
        var resolved: File {
            guard mimeType == GoogleDrive.shortcutMime, let target = shortcutDetails else { return self }
            var file = self
            file.id = target.targetId
            file.mimeType = target.targetMimeType
            file.shortcutDetails = nil
            return file
        }

        var isFolder: Bool { resolved.mimeType == GoogleDrive.folderMime }

        /// A Google Doc, Sheet or the like: it has no file to download (it would have to be exported).
        var isGoogleApp: Bool {
            let kind = resolved.mimeType
            return kind.hasPrefix("application/vnd.google-apps.") && kind != GoogleDrive.folderMime
        }

        var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    }

    /// A page of a listing.
    struct Listing: Decodable {
        var files: [File]
        var nextPageToken: String?

        enum CodingKeys: String, CodingKey { case files, nextPageToken }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // one entry Drive describes oddly is left out, not the whole page
            files = ((try? c.decode([Lossy].self, forKey: .files)) ?? []).compactMap(\.file)
            nextPageToken = try? c.decode(String.self, forKey: .nextPageToken)
        }

        private struct Lossy: Decodable {
            var file: File?
            init(from decoder: Decoder) throws { file = try? File(from: decoder) }
        }
    }

    /// RFC 3339, with or without fractional seconds: "2026-10-18T19:03:51.123Z".
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// What a book file is called when it can be imported: the same set the Files picker offers.
    static func isImportableName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["epub", "pdf", "cbz", "zip", "fbz", "rtf"].contains(ext)
            || Book.audioExtensions.contains(ext)
            || TextBook.format(forExtension: ext) != nil
    }

    /// A file that can go into the library (not a folder, not a Google Doc).
    static func isImportable(_ file: File) -> Bool {
        !file.isFolder && !file.isGoogleApp && isImportableName(file.name)
    }

    // MARK: Books that live in the Drive

    /// A Drive file a library book is made of.
    struct FileRef: Codable, Hashable {
        var id: String
        /// The name Drive gives it: the local copy's extension comes from it.
        var name: String
        var size: Int64?
        var md5: String?

        init(_ file: File) {
            id = file.id
            name = file.name
            size = file.size
            md5 = file.md5Checksum
        }

        init(id: String, name: String, size: Int64? = nil, md5: String? = nil) {
            self.id = id
            self.name = name
            self.size = size
            self.md5 = md5
        }
    }

    /// Where a library book comes from when it was added from the Drive without being downloaded: the files it is
    /// made of, in play order. The book exists in the library at once; its files come down one book at a time, when asked.
    struct Source: Codable, Hashable {
        var parts: [FileRef]
        /// The title the library gave it from the file and folder names. Once the file is open its own title replaces
        /// this — unless the reader has changed it meanwhile.
        var guessedTitle: String
        /// What the downloaded files say about the book (title, author, cover…) has been read.
        var finished = false

        var bytes: Int64 { parts.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    // MARK: Queries

    /// A value inside a query's single quotes.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func children(of folderID: String) -> String { "\(quoted(folderID)) in parents and trashed = false" }
    static let sharedWithMe = "sharedWithMe = true and trashed = false"

    static func inFolder(_ name: String, parent: String) -> String {
        "\(children(of: parent)) and name = \(quoted(name)) and mimeType = \(quoted(folderMime))"
    }

    static let fileFields = "id,name,mimeType,size,modifiedTime,md5Checksum,shortcutDetails(targetId,targetMimeType)"

    /// One page of a listing: folders first, then by name as a person sorts them.
    static func listURL(query: String, pageToken: String? = nil, pageSize: Int = 200) -> URL? {
        var parts = URLComponents(string: "\(apiBase)/files")
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "nextPageToken,files(\(fileFields))"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        parts?.queryItems = items
        return parts?.url
    }

    static func downloadURL(id: String) -> URL? {
        var parts = URLComponents(string: "\(apiBase)/files/\(id)")
        // acknowledgeAbuse: without it a file too big for Drive's virus scan answers
        // with a warning page (HTTP 200, HTML) instead of the bytes — which players
        // and importers then read as a broken book
        parts?.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "acknowledgeAbuse", value: "true"),
        ]
        return parts?.url
    }

    static func fileURL(id: String, fields: String = fileFields + ",trashed") -> URL? {
        var parts = URLComponents(string: "\(apiBase)/files/\(id)")
        parts?.queryItems = [URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        return parts?.url
    }

    // MARK: Changes

    /// Where the Drive's list of changes begins now — what a later `changesURL` asks from.
    static var startTokenURL: URL? {
        var parts = URLComponents(string: "\(apiBase)/changes/startPageToken")
        parts?.queryItems = [URLQueryItem(name: "supportsAllDrives", value: "true")]
        return parts?.url
    }

    /// The first page of what changed since `token`: one entry is enough to know that something did.
    static func changesURL(token: String) -> URL? {
        var parts = URLComponents(string: "\(apiBase)/changes")
        parts?.queryItems = [
            URLQueryItem(name: "pageToken", value: token),
            URLQueryItem(name: "pageSize", value: "1"),
            URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId)"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        return parts?.url
    }

    /// What Drive says about the changes since a token: whether there are any, and the token to ask from next time
    /// (when there were none).
    struct Changes: Decodable, Equatable {
        var any: Bool
        var next: String?

        enum CodingKeys: String, CodingKey { case changes, newStartPageToken, nextPageToken }
        struct Entry: Decodable {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let entries = (try? c.decode([Entry].self, forKey: .changes)) ?? []
            any = !entries.isEmpty || (try? c.decode(String.self, forKey: .nextPageToken)) != nil
            next = try? c.decode(String.self, forKey: .newStartPageToken)
        }

        init(any: Bool, next: String?) {
            self.any = any
            self.next = next
        }
    }

    static func deleteURL(id: String) -> URL? { URL(string: "\(apiBase)/files/\(id)?supportsAllDrives=true") }

    static let aboutURL = URL(string: "\(apiBase)/about?fields=user(displayName,emailAddress)")!

    /// The body that makes a folder (or, with `mime` and `parent`, describes an upload).
    static func metadata(name: String, mime: String, parent: String? = nil) -> Data {
        var object: [String: Any] = ["name": name, "mimeType": mime]
        if let parent { object["parents"] = [parent] }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static var resumableUploadURL: URL? { URL(string: "\(uploadBase)/files?uploadType=resumable&supportsAllDrives=true&fields=id,name") }

    // MARK: Uploading

    /// A resumable upload goes up in pieces this big (a multiple of 256 KiB, as Drive requires): a dropped connection
    /// costs one piece, not the whole backup, and the access token is looked at between pieces.
    static let uploadChunk = 8 * 1024 * 1024

    /// The `Content-Range` of the piece covering bytes `start` up to but not including `end` of `total`.
    static func contentRange(start: Int64, end: Int64, total: Int64) -> String {
        end > start ? "bytes \(start)-\(end - 1)/\(total)" : "bytes */\(total)"
    }

    /// Where an upload that answered 308 wants the next byte: after the last one its `Range` header says it holds
    /// ("bytes=0-8388607"), or 0 when it holds none.
    static func nextOffset(fromRange header: String?) -> Int64 {
        guard let header, let dash = header.lastIndex(of: "-"), let last = Int64(header[header.index(after: dash)...]) else { return 0 }
        return last + 1
    }

    // MARK: Sign-in

    /// A client ID looks like "1234-abcd.apps.googleusercontent.com" — the iOS kind, which needs no secret.
    static func isClientID(_ text: String) -> Bool {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.hasSuffix(clientIDSuffix) && id.count > clientIDSuffix.count + 4 && !id.contains(" ")
    }

    /// "com.googleusercontent.apps.1234-abcd": the client ID turned around, which is the scheme Google sends the
    /// reader back to the app on.
    static func redirectScheme(clientID: String) -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isClientID(id) else { return nil }
        return "com.googleusercontent.apps." + id.dropLast(clientIDSuffix.count)
    }

    static func redirectURI(clientID: String) -> String? {
        redirectScheme(clientID: clientID).map { $0 + ":/oauth2redirect" }
    }

    /// The page the reader signs in on: authorization code flow with PKCE, asking for offline access so a refresh
    /// token comes back and the sign-in lasts.
    static func authURL(clientID: String, challenge: String, state: String) -> URL? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let redirect = redirectURI(clientID: id), var parts = URLComponents(string: authEndpoint) else { return nil }
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return parts.url
    }

    enum SignInFailure: Error, Equatable {
        case cancelled
        case denied
        case mismatch
        case failed(String)
    }

    /// The code Google sent the reader back with, or why there is none. A reply with another `state` is not
    /// the answer to this sign-in.
    static func code(fromCallback url: URL, expectedState: String) -> Result<String, SignInFailure> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            return .failure(error == "access_denied" ? .denied : .failed(error))
        }
        guard value("state") == expectedState else { return .failure(.mismatch) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.failed("no code")) }
        return .success(code)
    }

    /// A form body, percent-encoded the way a token endpoint wants it.
    static func form(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return Data(items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    static func codeExchange(code: String, verifier: String, clientID: String) -> Data? {
        guard let redirect = redirectURI(clientID: clientID) else { return nil }
        return form([
            ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
            ("client_id", clientID.trimmingCharacters(in: .whitespacesAndNewlines)), ("redirect_uri", redirect),
        ])
    }

    static func refresh(token: String, clientID: String) -> Data {
        form([
            ("grant_type", "refresh_token"), ("refresh_token", token),
            ("client_id", clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
    }

    /// What the token endpoint answers a code or a refresh with.
    struct TokenReply: Decodable, Equatable {
        var accessToken: String
        var expiresIn: Double
        var refreshToken: String?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token", scope
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            expiresIn = (try? c.decode(Double.self, forKey: .expiresIn)) ?? 3600
            refreshToken = try? c.decode(String.self, forKey: .refreshToken)
            scope = try? c.decode(String.self, forKey: .scope)
        }

        init(accessToken: String, expiresIn: Double, refreshToken: String? = nil, scope: String? = nil) {
            self.accessToken = accessToken
            self.expiresIn = expiresIn
            self.refreshToken = refreshToken
            self.scope = scope
        }
    }

    /// Whether an access token can still be used: a minute of slack, so one is not sent as it expires.
    static func isFresh(expires: Date?, now: Date, slack: TimeInterval = 60) -> Bool {
        guard let expires else { return false }
        return expires.timeIntervalSince(now) > slack
    }

    /// The scopes a sign-in was actually granted (the reader can untick one on Google's page).
    static func grantedAll(_ scope: String?) -> Bool {
        let granted = Set((scope ?? "").split(separator: " ").map(String.init))
        return Set(scopes).isSubset(of: granted)
    }

    /// URL-safe base64 without padding: how PKCE writes a challenge and a verifier.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Errors

    /// What a failed request says, in words. `body` is Google's JSON error where there was one.
    static func explain(status: Int, body: Data?) -> String {
        let (message, reason) = errorDetail(body)
        switch status {
        case 401:
            return "Google has signed Pageturner out. Sign in again."
        case 403:
            if reason == "accessNotConfigured" || (message ?? "").contains("has not been used in project") {
                return "The Google Drive API is not switched on in your Google Cloud project. Enable it (APIs & Services → Library → Google Drive API), wait a minute, and try again."
            }
            if reason == "rateLimitExceeded" || reason == "userRateLimitExceeded" || reason == "dailyLimitExceeded" {
                return "Google says that is too many requests for now. Try again in a little while."
            }
            if reason == "insufficientPermissions" || reason == "forbidden" {
                return "Pageturner was not allowed to do that. Sign out and in again, and tick every permission Google lists."
            }
            return "Google would not allow that" + (message.map { ": \($0)" } ?? ".")
        case 404:
            return "That is gone, or not shared with you any more."
        case 429:
            return "Google says that is too many requests for now. Try again in a little while."
        case 500 ... 599:
            return "Google Drive had a problem (\(status)). Try again in a moment."
        default:
            return "Google Drive answered \(status)" + (message.map { ": \($0)" } ?? ".")
        }
    }

    private static func errorDetail(_ body: Data?) -> (message: String?, reason: String?) {
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return (nil, nil) }
        let reason = ((error["errors"] as? [[String: Any]])?.first?["reason"] as? String)
            ?? ((error["details"] as? [[String: Any]])?.first?["reason"] as? String)
        return (error["message"] as? String, reason)
    }

    /// What the token endpoint's error means to the reader. `invalid_grant` is what a refresh token that has been
    /// revoked or has run out (a project in Google's "Testing" mode lets them last a week) answers with.
    static func explainSignIn(errorCode: String?) -> String {
        switch errorCode {
        case "invalid_grant":
            return "Google no longer accepts the saved sign-in (it was revoked, or a project in Testing mode lets it last only a week). Sign in again."
        case "invalid_client", "unauthorized_client":
            return "Google does not recognise Pageturner’s sign-in ID (it may have been deleted in Google Cloud, or this build is out of date)."
        case "access_denied":
            return "Google did not give access. If the app is in Testing mode, add your Google account under Test users."
        case "redirect_uri_mismatch", "invalid_request":
            return "Google rejected the sign-in request. Check that the client ID is the iOS kind and is copied whole."
        default:
            return "Google sign-in failed" + (errorCode.map { " (\($0))" } ?? ".")
        }
    }

    /// Whether a request that failed is worth asking again, and how long to wait first.
    static func shouldRetry(status: Int) -> Bool { status == 429 || (500 ... 599).contains(status) }

    static func retryDelay(attempt: Int) -> TimeInterval { min(30, pow(2, Double(max(0, attempt)))) }

    // MARK: Watching a folder

    /// What marks one version of a file: its id and what it holds (its checksum, or its size and time where
    /// Drive has no checksum). An edited file is a new version and comes in again.
    static func syncKey(_ file: File) -> String {
        let version = file.md5Checksum ?? "\(file.size ?? 0)-\(Int(file.modifiedTime?.timeIntervalSince1970 ?? 0))"
        return "\(file.id)|\(version)"
    }

    /// The files a scan should bring in: importable, not seen before, and not touched this very moment (one still
    /// being uploaded is left for the next scan).
    static func newFiles(_ files: [File], seen: Set<String>, now: Date, settle: TimeInterval = 30) -> [File] {
        files.filter { file in
            guard isImportable(file), !seen.contains(syncKey(file)) else { return false }
            if let modified = file.modifiedTime, now.timeIntervalSince(modified) < settle { return false }
            return true
        }
    }

    /// The remembered keys with these added, the oldest dropped beyond `max`.
    static func remembering(_ seen: [String], adding keys: [String], max: Int) -> [String] {
        var out = seen
        let known = Set(seen)
        for key in keys where !known.contains(key) { out.append(key) }
        return Array(out.suffix(max))
    }

    // MARK: Backups

    /// This app's own backup zips among a folder's files, newest first.
    static func backups(_ files: [File]) -> [File] {
        files.filter { !$0.isFolder && AutoBackupPlan.isBackupFile($0.name) }.sorted { $0.name > $1.name }
    }

    /// The copies to delete so only the newest `keep` remain, oldest first. Anything that is not one of this app's
    /// backups is never named.
    static func staleBackups(_ files: [File], keep: Int) -> [File] {
        let stale = Set(AutoBackupPlan.stale(files.map(\.name), keep: keep))
        return backups(files).filter { stale.contains($0.name) }.reversed()
    }

    /// "1.2 GB" — what a file in a list says about its size; nothing when Drive gave none.
    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
