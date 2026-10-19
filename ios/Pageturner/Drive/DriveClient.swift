import Foundation

/// The Google Drive API: listing, downloading, and keeping Pageturner's own backups. Every request carries the
/// access token `GoogleAuth` holds; a refused one is renewed once, and a busy answer is asked again after a wait.
/// What the requests say and how errors read is `GoogleDrive` (pure, checked off-device).
@MainActor
final class DriveClient {
    static let shared = DriveClient()

    private let auth = GoogleAuth.shared
    private let session: URLSession
    private static let backupFolderKey = "drive-backup-folder"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: One request

    /// A request with the bearer on it. `again`: whether a lost connection or a busy answer may be tried a few times
    /// (not for one that would make a second folder).
    private func perform(_ base: URLRequest, body: Data? = nil, again: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var renewed = false
        while true {
            var request = base
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                if let body { (data, response) = try await session.upload(for: request, from: body) }
                else { (data, response) = try await session.data(for: request) }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard again, attempt < 2 else { throw DriveError.offline }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(GoogleDrive.retryDelay(attempt: attempt) * 1_000_000_000))
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw DriveError.offline }
            if (200 ..< 300).contains(http.statusCode) { return (data, http) }
            if http.statusCode == 401, !renewed {
                renewed = true
                auth.discardAccessToken()
                continue
            }
            if again, GoogleDrive.shouldRetry(status: http.statusCode), attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(GoogleDrive.retryDelay(attempt: attempt) * 1_000_000_000))
                continue
            }
            throw DriveError(message: GoogleDrive.explain(status: http.statusCode, body: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DriveError(message: "Google Drive sent something Pageturner could not read.") }
    }

    // MARK: Listing

    /// Everything a query finds, page after page, up to `limit`.
    func list(query: String, limit: Int = 1500) async throws -> [GoogleDrive.File] {
        var found: [GoogleDrive.File] = []
        var token: String?
        repeat {
            guard let url = GoogleDrive.listURL(query: query, pageToken: token) else { break }
            let (data, _) = try await perform(URLRequest(url: url))
            let page = try decode(GoogleDrive.Listing.self, from: data)
            found += page.files
            token = page.nextPageToken
        } while token != nil && found.count < limit
        return found
    }

    func children(of folderID: String) async throws -> [GoogleDrive.File] {
        try await list(query: GoogleDrive.children(of: folderID))
    }

    func sharedWithMe() async throws -> [GoogleDrive.File] {
        try await list(query: GoogleDrive.sharedWithMe)
    }

    func file(id: String) async throws -> GoogleDrive.File {
        guard let url = GoogleDrive.fileURL(id: id) else { throw DriveError(message: "That Drive address can’t be used.") }
        let (data, _) = try await perform(URLRequest(url: url))
        return try decode(GoogleDrive.File.self, from: data)
    }

    /// Every book file under a folder, subfolders included (to a sensible depth and count), each with the folders
    /// between it and the one asked about ("Dune/CD 1"), so an audiobook's parts can be kept together.
    func books(under folderID: String, depth: Int = 8, limit: Int = 1000) async throws -> [(file: GoogleDrive.File, folder: String)] {
        var books: [(file: GoogleDrive.File, folder: String)] = []
        var queue: [(id: String, level: Int, path: String)] = [(folderID, 0, "")]
        var visited: Set<String> = [folderID]
        while !queue.isEmpty, books.count < limit {
            let (id, level, path) = queue.removeFirst()
            for file in try await children(of: id) {
                if file.isFolder {
                    let target = file.resolved.id
                    if level < depth, visited.insert(target).inserted {
                        queue.append((target, level + 1, path.isEmpty ? file.name : path + "/" + file.name))
                    }
                } else if GoogleDrive.isImportable(file) {
                    books.append((file.resolved, path))
                }
            }
        }
        return books
    }

    // MARK: Downloading

    /// One file into `directory` under its own name (a number is added when two share a name). Throws when what
    /// arrived is not the size Drive says it is.
    func download(_ file: GoogleDrive.File, into directory: URL) async throws -> URL {
        let file = file.resolved
        guard let url = GoogleDrive.downloadURL(id: file.id) else { throw DriveError(message: "That Drive address can’t be used.") }
        var renewed = false
        while true {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            let temp: URL
            let response: URLResponse
            do {
                (temp, response) = try await session.download(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw DriveError.offline
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                let body = try? Data(contentsOf: temp)
                try? FileManager.default.removeItem(at: temp)
                if status == 401, !renewed {
                    renewed = true
                    auth.discardAccessToken()
                    continue
                }
                throw DriveError(message: "\(file.name): " + GoogleDrive.explain(status: status, body: body))
            }
            let destination = Self.freeName(for: file.name, in: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: destination)
            if let expected = file.size,
               let got = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(got) != expected {
                try? FileManager.default.removeItem(at: destination)
                throw DriveError(message: "\(file.name) did not come down whole. Try again.")
            }
            return destination
        }
    }

    /// A name in `directory` nothing has yet: a file name cannot hold "/", and "Book.epub" taken becomes "Book 2.epub".
    nonisolated static func freeName(for name: String, in directory: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safe.isEmpty ? "file" : safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Backups

    /// The folder this app's backups go in: the one it made before (kept by id, checked to still be there), else a
    /// new "Pageturner Backups". With the `drive.file` scope the app can write only to folders it made itself.
    func backupFolder() async throws -> GoogleDrive.File {
        if let id = UserDefaults.standard.string(forKey: Self.backupFolderKey),
           let folder = try? await file(id: id), folder.isFolder, folder.trashed != true {
            return folder
        }
        let folder = try await createFolder(named: GoogleDrive.backupFolderName, in: nil)
        UserDefaults.standard.set(folder.id, forKey: Self.backupFolderKey)
        return folder
    }

    func createFolder(named name: String, in parent: String?) async throws -> GoogleDrive.File {
        guard var parts = URLComponents(string: "\(GoogleDrive.apiBase)/files") else { throw DriveError.offline }
        parts.queryItems = [URLQueryItem(name: "fields", value: GoogleDrive.fileFields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        guard let url = parts.url else { throw DriveError.offline }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await perform(request, body: GoogleDrive.metadata(name: name, mime: GoogleDrive.folderMime, parent: parent), again: false)
        return try decode(GoogleDrive.File.self, from: data)
    }

    /// Every backup this app made, wherever in the Drive it now is, newest first.
    func backups() async throws -> [GoogleDrive.File] {
        let found = try await list(query: "name contains '\(AutoBackupPlan.filePrefix)' and trashed = false", limit: 300)
        return GoogleDrive.backups(found)
    }

    func delete(_ id: String) async throws {
        guard let url = GoogleDrive.deleteURL(id: id) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    // MARK: Uploading

    /// Send a file to a folder, in pieces: a dropped connection costs a piece, not the whole backup, and where an
    /// upload had got to is asked for before it goes on. `progress` is 0…1.
    @discardableResult
    func upload(
        _ fileURL: URL, name: String, to parent: String, mime: String = "application/zip",
        progress: ((Double) -> Void)? = nil
    ) async throws -> GoogleDrive.File {
        let total = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let start = GoogleDrive.resumableUploadURL else { throw DriveError.offline }
        var begin = URLRequest(url: start)
        begin.httpMethod = "POST"
        begin.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        begin.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        begin.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, started) = try await perform(begin, body: GoogleDrive.metadata(name: name, mime: mime, parent: parent), again: false)
        guard let location = started.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
            throw DriveError(message: "Google Drive did not start the upload.")
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let noRedirects = NoRedirects()
        var offset: Int64 = 0
        var failures = 0
        while true {
            let end = min(offset + Int64(GoogleDrive.uploadChunk), total)
            try handle.seek(toOffset: UInt64(offset))
            let piece = try handle.read(upToCount: Int(end - offset)) ?? Data()
            var request = URLRequest(url: target)
            request.httpMethod = "PUT"
            request.timeoutInterval = 120
            request.setValue(GoogleDrive.contentRange(start: offset, end: end, total: total), forHTTPHeaderField: "Content-Range")
            if let token = try? await auth.accessToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await session.upload(for: request, from: piece, delegate: noRedirects)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 || status == 201 {
                    progress?(1)
                    return try decode(GoogleDrive.File.self, from: data)
                }
                if status == 308 {
                    offset = GoogleDrive.nextOffset(fromRange: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"))
                    progress?(total > 0 ? Double(offset) / Double(total) : 1)
                    failures = 0
                    continue
                }
                if status == 401 { auth.discardAccessToken() }
                guard status == 401 || GoogleDrive.shouldRetry(status: status), failures < 5 else {
                    throw DriveError(message: GoogleDrive.explain(status: status, body: data))
                }
            } catch let failure as DriveError {
                throw failure
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard failures < 5 else { throw DriveError.offline }
            }
            // something went wrong with this piece: wait, then ask where the upload stands and go on from there
            failures += 1
            try await Task.sleep(nanoseconds: UInt64(GoogleDrive.retryDelay(attempt: failures) * 1_000_000_000))
            switch await resume(target, total: total, delegate: noRedirects) {
            case let .at(next): offset = next
            case let .done(file): progress?(1); return file
            case .unknown: break   // the same piece again
            }
        }
    }

    private enum Resume {
        case at(Int64)
        case done(GoogleDrive.File)
        case unknown
    }

    /// Where an upload has got to: the next byte it wants, or the finished file when only the answer was lost.
    private func resume(_ target: URL, total: Int64, delegate: URLSessionTaskDelegate) async -> Resume {
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(GoogleDrive.contentRange(start: 0, end: 0, total: total), forHTTPHeaderField: "Content-Range")
        guard let (data, response) = try? await session.upload(for: request, from: Data(), delegate: delegate),
              let http = response as? HTTPURLResponse
        else { return .unknown }
        if http.statusCode == 308 { return .at(GoogleDrive.nextOffset(fromRange: http.value(forHTTPHeaderField: "Range"))) }
        if http.statusCode == 200 || http.statusCode == 201, let file = try? JSONDecoder().decode(GoogleDrive.File.self, from: data) {
            return .done(file)
        }
        return .unknown
    }
}

/// An upload's "308 Resume Incomplete" is an answer to read, not a redirect to follow.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
