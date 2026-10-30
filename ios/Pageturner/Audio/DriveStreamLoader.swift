import AVFoundation
import Foundation

/// Plays a file from Google Drive without downloading it: AVFoundation is given a `ptdrive://` address instead of the
/// Drive's own, and asks this loader for the bytes it wants. A Drive download link has no file extension and answers with
/// a generic content type, so AVFoundation given it directly cannot tell what the file is or how long it lasts ("can't
/// determine length"); here the size (from Drive's listing) and the kind (from the file name) are told to it up front,
/// and each range it asks for is fetched with the sign-in token, a megabyte at a time.
final class DriveStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "ptdrive"
    let queue = DispatchQueue(label: "pageturner.drive-stream")

    private let lock = NSLock()
    private var token: String
    private var work: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let session: URLSession
    private let refresh: @Sendable () async -> String?
    private static let chunk: Int64 = 1_048_576

    init(token: String, refresh: @escaping @Sendable () async -> String?) {
        self.token = token
        self.refresh = refresh
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func setToken(_ new: String) {
        lock.lock(); token = new; lock.unlock()
    }

    private func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    /// The address AVFoundation is given for one Drive file: who it is, how big, and (in the name) what kind.
    static func url(file: String, size: Int64, name: String) -> URL? {
        let ext = (name as NSString).pathExtension.lowercased()
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "drive"   // a host is lower-cased on its way; the case-sensitive id travels in the query
        parts.path = "/audio" + (ext.isEmpty ? "" : "." + ext)
        parts.queryItems = [URLQueryItem(name: "size", value: String(size)), URLQueryItem(name: "id", value: file)]
        return parts.url
    }

    private static func contentType(_ ext: String) -> String {
        switch ext {
        case "mp3": return "public.mp3"
        case "m4a", "m4b", "mp4": return "com.apple.m4a-audio"
        case "aac": return "public.aac-audio"
        case "wav": return "com.microsoft.waveform-audio"
        case "flac": return "org.xiph.flac"
        case "caf": return "com.apple.coreaudio-format"
        default: return "public.audio"
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty
        else { return false }
        let declared = Int64(items.first(where: { $0.name == "size" })?.value ?? "") ?? 0
        let ext = url.pathExtension.lowercased()
        let task = Task { [weak self] in
            // a loader that went away mid-answer still owes the request an ending
            guard let self else { request.finishLoading(with: URLError(.cancelled)); return }
            defer { self.finish(request) }
            // a size Drive did not give is found out from the first byte's answer
            let size = declared > 0 ? declared : (await self.fetchSize(id) ?? 0)
            guard size > 0 else {
                request.finishLoading(with: URLError(.badServerResponse))
                return
            }
            if let info = request.contentInformationRequest {
                info.contentLength = size
                info.isByteRangeAccessSupported = true
                info.contentType = Self.contentType(ext)
            }
            guard let data = request.dataRequest else {
                request.finishLoading()
                return
            }
            var offset = data.currentOffset
            let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
            while offset < end, !Task.isCancelled {
                let to = min(end, offset + Self.chunk)
                guard let bytes = await self.fetch(id, from: offset, to: to - 1), !bytes.isEmpty else {
                    if !Task.isCancelled { request.finishLoading(with: URLError(.badServerResponse)) }
                    return
                }
                data.respond(with: bytes)
                offset += Int64(bytes.count)
            }
            if !Task.isCancelled { request.finishLoading() }
        }
        lock.lock(); work[ObjectIdentifier(request)] = task; lock.unlock()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.lock()
        let task = work.removeValue(forKey: ObjectIdentifier(request))
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ request: AVAssetResourceLoadingRequest) {
        lock.lock(); work[ObjectIdentifier(request)] = nil; lock.unlock()
    }

    // MARK: The wire

    /// A range, asked again (twice, after a pause) when the network drops or Drive says to slow down — one blip
    /// must not end a book.
    private func fetch(_ id: String, from: Int64, to: Int64) async -> Data? {
        for attempt in 0 ... 2 {
            if let data = await fetchOnce(id, from: from, to: to) { return data }
            if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000) }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private func fetchOnce(_ id: String, from: Int64, to: Int64) async -> Data? {
        guard let url = GoogleDrive.downloadURL(id: id) else { return nil }
        var renewed = false
        while true {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(currentToken())", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401, !renewed {
                renewed = true
                if let fresh = await refresh() { setToken(fresh); continue }
                return nil
            }
            guard http.statusCode == 206 || http.statusCode == 200,
                  // Drive's error and virus-scan pages come back 200 with HTML — feeding them to
                  // the player makes it report "Cannot Open" on a file that is really unreachable
                  !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html")
            else { return nil }
            // a server that ignored the range sent the whole file: the part wanted is cut from it
            if http.statusCode == 200, from > 0 || Int64(data.count) > to - from + 1 {
                let lower = Int(min(Int64(data.count), from)), upper = Int(min(Int64(data.count), to + 1))
                return data.subdata(in: lower ..< upper)
            }
            return data
        }
    }

    private func fetchSize(_ id: String) async -> Int64? {
        guard let url = GoogleDrive.downloadURL(id: id) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last
        else { return nil }
        return Int64(total)
    }
}
