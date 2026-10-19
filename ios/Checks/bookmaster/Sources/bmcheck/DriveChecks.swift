import Foundation

// Checks for Google Drive in Pageturner: reading Drive's answers, the queries and sign-in addresses, which files
// are books, what is new in a watched folder, which backups to clear away, and what an error says.

@MainActor
func runDriveChecks() {
    section("Google Drive")

    // ---- reading a listing
    let json = """
    {"nextPageToken":"next-1","files":[
      {"id":"f1","name":"Dune.epub","mimeType":"application/epub+zip","size":"1048576","modifiedTime":"2026-10-18T19:03:51.123Z","md5Checksum":"abc"},
      {"id":"d1","name":"Audiobooks","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2026-10-01T10:00:00Z"},
      {"id":"s1","name":"Shared Shelf","mimeType":"application/vnd.google-apps.shortcut","shortcutDetails":{"targetId":"d2","targetMimeType":"application/vnd.google-apps.folder"}},
      {"id":"g1","name":"Reading list","mimeType":"application/vnd.google-apps.document"},
      {"name":"no id at all"},
      {"id":"f2","name":"Notes.txt","mimeType":"text/plain","size":12}
    ]}
    """.data(using: .utf8)!
    let listing = try? JSONDecoder().decode(GoogleDrive.Listing.self, from: json)
    check("a listing is read, with its next page, and an entry with no id is left out and not the page",
          listing?.files.map(\.id) == ["f1", "d1", "s1", "g1", "f2"] && listing?.nextPageToken == "next-1",
          "\(listing?.files.map(\.id) ?? [])")
    let dune = listing?.files.first
    check("a size sent as a string is a number, and a time with fractions is a date",
          dune?.size == 1_048_576 && dune?.md5Checksum == "abc"
          && abs((dune?.modifiedTime?.timeIntervalSince(GoogleDrive.date("2026-10-18T19:03:51Z") ?? .distantPast) ?? 0) - 0.123) < 0.001,
          "\(String(describing: dune?.modifiedTime))")
    check("a size sent as a number is read too", listing?.files.last?.size == 12)
    check("a time without fractions is read", GoogleDrive.date("2026-10-01T10:00:00Z") != nil && GoogleDrive.date("yesterday") == nil)
    let shortcut = listing?.files[2]
    check("a shortcut to a folder is that folder", shortcut?.isFolder == true && shortcut?.resolved.id == "d2" && shortcut?.resolved.name == "Shared Shelf")
    check("one file looked at says whether it is in the bin",
          (try? JSONDecoder().decode(GoogleDrive.File.self, from: Data(#"{"id":"a","name":"n","mimeType":"x","trashed":true}"#.utf8)))?.trashed == true
          && listing?.files.first?.trashed == nil
          && GoogleDrive.fileURL(id: "a")?.absoluteString.contains("trashed") == true)
    check("a Google Doc is not a file to download", listing?.files[3].isGoogleApp == true && listing?.files[1].isGoogleApp == false)

    // ---- what is a book
    check("books, audio, text and archives come in",
          ["a.epub", "A.PDF", "x.cbz", "b.zip", "c.m4b", "c.mp3", "n.txt", "n.md", "n.html"].allSatisfy(GoogleDrive.isImportableName))
    check("other things do not", !["a.docx", "a.jpg", "noextension", "a.epub.bak", "a.mobi"].contains(where: GoogleDrive.isImportableName))
    check("a folder, a Google Doc and a book file are told apart",
          GoogleDrive.isImportable(dune!) && !GoogleDrive.isImportable(listing!.files[1])
          && !GoogleDrive.isImportable(listing!.files[3]) && GoogleDrive.isImportable(listing!.files[4]))

    // ---- queries
    check("a quote in a name cannot end the query", GoogleDrive.quoted("it's a \\ test") == "'it\\'s a \\\\ test'")
    check("a folder's children, not in the bin", GoogleDrive.children(of: "abc") == "'abc' in parents and trashed = false")
    check("a folder is found by name inside its parent",
          GoogleDrive.inFolder("Pageturner Backups", parent: "root") == "'root' in parents and trashed = false and name = 'Pageturner Backups' and mimeType = 'application/vnd.google-apps.folder'")
    let url = GoogleDrive.listURL(query: GoogleDrive.children(of: "abc"), pageToken: "tok")
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
    check("a listing asks for what the browser shows, folders first, shared drives included",
          url?.host == "www.googleapis.com" && url?.path == "/drive/v3/files" && item("q") == "'abc' in parents and trashed = false"
          && item("orderBy") == "folder,name_natural" && item("supportsAllDrives") == "true" && item("pageToken") == "tok"
          && item("fields")?.contains("md5Checksum") == true && item("pageSize") == "200")
    check("a download asks for the file's content", GoogleDrive.downloadURL(id: "f1")?.absoluteString == "https://www.googleapis.com/drive/v3/files/f1?alt=media&supportsAllDrives=true")
    check("a backup upload is a resumable one that returns the new file's id",
          GoogleDrive.resumableUploadURL?.absoluteString.contains("uploadType=resumable") == true)
    let meta = (try? JSONSerialization.jsonObject(with: GoogleDrive.metadata(name: "x.zip", mime: "application/zip", parent: "p1"))) as? [String: Any]
    check("an upload names its folder", meta?["name"] as? String == "x.zip" && (meta?["parents"] as? [String]) == ["p1"])

    check("a piece of an upload says which bytes it is", GoogleDrive.contentRange(start: 0, end: 8_388_608, total: 20_000_000) == "bytes 0-8388607/20000000"
          && GoogleDrive.contentRange(start: 16_777_216, end: 20_000_000, total: 20_000_000) == "bytes 16777216-19999999/20000000"
          && GoogleDrive.contentRange(start: 0, end: 0, total: 0) == "bytes */0" && GoogleDrive.uploadChunk % 262_144 == 0)
    check("an upload's answer says where to go on", GoogleDrive.nextOffset(fromRange: "bytes=0-8388607") == 8_388_608
          && GoogleDrive.nextOffset(fromRange: nil) == 0 && GoogleDrive.nextOffset(fromRange: "junk") == 0)

    // ---- signing in
    let clientID = "123456-abcdef.apps.googleusercontent.com"
    check("a client ID is the iOS kind, written whole", GoogleDrive.isClientID(clientID) && GoogleDrive.isClientID("  \(clientID)\n")
          && !GoogleDrive.isClientID("123456-abcdef") && !GoogleDrive.isClientID(".apps.googleusercontent.com") && !GoogleDrive.isClientID("a b.apps.googleusercontent.com"))
    check("the redirect is the client ID turned around", GoogleDrive.redirectScheme(clientID: clientID) == "com.googleusercontent.apps.123456-abcdef"
          && GoogleDrive.redirectURI(clientID: clientID) == "com.googleusercontent.apps.123456-abcdef:/oauth2redirect"
          && GoogleDrive.redirectURI(clientID: "nope") == nil)
    let auth = GoogleDrive.authURL(clientID: clientID, challenge: "CHAL", state: "ST")
    let authItems = auth.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    func authItem(_ name: String) -> String? { authItems.first { $0.name == name }?.value }
    check("the sign-in page asks for a code with PKCE, offline, for both scopes",
          auth?.host == "accounts.google.com" && authItem("response_type") == "code" && authItem("code_challenge") == "CHAL"
          && authItem("code_challenge_method") == "S256" && authItem("state") == "ST" && authItem("access_type") == "offline"
          && authItem("client_id") == clientID && authItem("redirect_uri") == "com.googleusercontent.apps.123456-abcdef:/oauth2redirect"
          && authItem("scope") == "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file")
    check("no sign-in page without a usable client ID", GoogleDrive.authURL(clientID: "nope", challenge: "c", state: "s") == nil)
    let back = URL(string: "com.googleusercontent.apps.123456-abcdef:/oauth2redirect?state=ST&code=4%2F0AbC&scope=x")!
    check("the code comes back with the state it was asked with", GoogleDrive.code(fromCallback: back, expectedState: "ST") == .success("4/0AbC"))
    check("a reply to another sign-in is refused", GoogleDrive.code(fromCallback: back, expectedState: "OTHER") == .failure(.mismatch))
    check("declining is told apart from failing",
          GoogleDrive.code(fromCallback: URL(string: "x:/cb?error=access_denied&state=ST")!, expectedState: "ST") == .failure(.denied)
          && GoogleDrive.code(fromCallback: URL(string: "x:/cb?error=server_error")!, expectedState: "ST") == .failure(.failed("server_error"))
          && GoogleDrive.code(fromCallback: URL(string: "x:/cb?state=ST")!, expectedState: "ST") == .failure(.failed("no code")))
    check("a form body is percent-encoded", String(data: GoogleDrive.form([("a b", "c&d=e+f"), ("g", "~-._")]), encoding: .utf8) == "a%20b=c%26d%3De%2Bf&g=~-._")
    let exchange = GoogleDrive.codeExchange(code: "4/0A", verifier: "VER", clientID: clientID).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check("the code is traded with the verifier, and no client secret",
          exchange.contains("grant_type=authorization_code") && exchange.contains("code=4%2F0A") && exchange.contains("code_verifier=VER")
          && exchange.contains("redirect_uri=com.googleusercontent.apps.123456-abcdef%3A%2Foauth2redirect") && !exchange.contains("secret"), exchange)
    check("a refresh needs only the token and the client ID",
          String(data: GoogleDrive.refresh(token: "r/1", clientID: clientID), encoding: .utf8) == "grant_type=refresh_token&refresh_token=r%2F1&client_id=\(clientID)")
    let reply = try? JSONDecoder().decode(GoogleDrive.TokenReply.self, from: Data(#"{"access_token":"at","expires_in":3599,"refresh_token":"rt","scope":"a b","token_type":"Bearer"}"#.utf8))
    check("a token answer is read", reply == GoogleDrive.TokenReply(accessToken: "at", expiresIn: 3599, refreshToken: "rt", scope: "a b"))
    check("a refresh answer has no new refresh token and still reads",
          (try? JSONDecoder().decode(GoogleDrive.TokenReply.self, from: Data(#"{"access_token":"at2","expires_in":3600}"#.utf8)))?.refreshToken == nil)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check("an access token is used until a minute before it runs out",
          GoogleDrive.isFresh(expires: t0.addingTimeInterval(3600), now: t0) && !GoogleDrive.isFresh(expires: t0.addingTimeInterval(30), now: t0)
          && !GoogleDrive.isFresh(expires: nil, now: t0))
    check("a sign-in that was not given every permission is noticed",
          GoogleDrive.grantedAll("https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file")
          && !GoogleDrive.grantedAll("https://www.googleapis.com/auth/drive.readonly") && !GoogleDrive.grantedAll(nil))
    check("PKCE's encoding is URL-safe without padding", GoogleDrive.base64URL(Data([0xfb, 0xff, 0xfe])) == "-__-" && GoogleDrive.base64URL(Data([0x01])) == "AQ")

    // ---- what an error says
    let notOn = Data(#"{"error":{"code":403,"message":"Google Drive API has not been used in project 123 before or it is disabled.","errors":[{"reason":"accessNotConfigured"}]}}"#.utf8)
    check("the Drive API being off is said plainly, since it is the usual setup slip",
          GoogleDrive.explain(status: 403, body: notOn).contains("not switched on"))
    check("a rate limit is told as one", GoogleDrive.explain(status: 403, body: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)).contains("too many requests")
          && GoogleDrive.explain(status: 429, body: nil).contains("too many requests"))
    check("signed out, gone and Google's own trouble are each said",
          GoogleDrive.explain(status: 401, body: nil).contains("Sign in again") && GoogleDrive.explain(status: 404, body: nil).contains("gone")
          && GoogleDrive.explain(status: 503, body: nil).contains("problem (503)"))
    check("a refused sign-in is explained by its code",
          GoogleDrive.explainSignIn(errorCode: "invalid_grant").contains("Sign in again") && GoogleDrive.explainSignIn(errorCode: "invalid_client").contains("iOS one")
          && GoogleDrive.explainSignIn(errorCode: "access_denied").contains("Test users") && GoogleDrive.explainSignIn(errorCode: nil).contains("failed"))
    check("busy answers are asked again, with growing waits; refusals are not",
          GoogleDrive.shouldRetry(status: 429) && GoogleDrive.shouldRetry(status: 503) && !GoogleDrive.shouldRetry(status: 403) && !GoogleDrive.shouldRetry(status: 404)
          && GoogleDrive.retryDelay(attempt: 0) == 1 && GoogleDrive.retryDelay(attempt: 3) == 8 && GoogleDrive.retryDelay(attempt: 20) == 30)

    // ---- a watched folder
    let now = Date(timeIntervalSince1970: 2_000_000)
    func book(_ id: String, _ name: String, md5: String? = "m", age: TimeInterval = 3600) -> GoogleDrive.File {
        GoogleDrive.File(id: id, name: name, mimeType: "application/epub+zip", size: 10, modifiedTime: now.addingTimeInterval(-age), md5Checksum: md5)
    }
    let folderFile = GoogleDrive.File(id: "d", name: "Sub", mimeType: GoogleDrive.folderMime)
    let doc = GoogleDrive.File(id: "g", name: "x.epub", mimeType: "application/vnd.google-apps.document")
    let seenKey = GoogleDrive.syncKey(book("a", "A.epub"))
    let fresh = GoogleDrive.newFiles(
        [book("a", "A.epub"), book("b", "B.epub"), book("c", "C.epub", age: 5), book("e", "E.docx"), folderFile, doc],
        seen: [seenKey], now: now)
    check("only what is new, finished and a book comes in", fresh.map(\.id) == ["b"], "\(fresh.map(\.id))")
    check("an edited file is a new version", GoogleDrive.syncKey(book("a", "A.epub", md5: "m2")) != seenKey
          && GoogleDrive.newFiles([book("a", "A.epub", md5: "m2")], seen: [seenKey], now: now).count == 1)
    check("a file with no checksum is told by size and time",
          GoogleDrive.syncKey(GoogleDrive.File(id: "z", name: "z.epub", mimeType: "x", size: 5, modifiedTime: Date(timeIntervalSince1970: 100))) == "z|5-100")
    check("remembered keys keep the newest and each once",
          GoogleDrive.remembering(["a", "b", "c"], adding: ["c", "d", "e"], max: 4) == ["b", "c", "d", "e"])

    // ---- backups in Drive
    func zip(_ id: String, _ day: String) -> GoogleDrive.File {
        GoogleDrive.File(id: id, name: "pageturner-backup-\(day).zip", mimeType: "application/zip", size: 1)
    }
    let files = [zip("1", "2026-10-01"), zip("3", "2026-10-15"), zip("2", "2026-10-08"), GoogleDrive.File(id: "x", name: "holiday.zip", mimeType: "application/zip"), folderFile]
    check("this app's backups are the newest first, and only them", GoogleDrive.backups(files).map(\.id) == ["3", "2", "1"])
    check("the oldest are cleared beyond the number kept, oldest first, and nothing else is named",
          GoogleDrive.staleBackups(files, keep: 2).map(\.id) == ["1"] && GoogleDrive.staleBackups(files, keep: 3).isEmpty
          && GoogleDrive.staleBackups(files, keep: 0).map(\.id) == ["1", "2"])
    check("a size reads as a person writes it", GoogleDrive.sizeText(nil) == "" && GoogleDrive.sizeText(1_500_000).contains("MB"))
}
