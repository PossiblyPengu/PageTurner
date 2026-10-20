import ImageIO
import SwiftUI
import UIKit

/// Remote jackets. One fetch path for every screen, instead of a scatter of
/// bare `AsyncImage`s: a session with a real URL cache and a User-Agent (some
/// cover endpoints answer a bare request slowly or not at all), misses under a
/// second still honoured from cache, and every URL list tried in order so a
/// 404 from Open Library falls through to the next source instead of sitting
/// on the placeholder forever.
enum CoverFetch {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 160 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Pageturner/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") cover-fetch"]
        return URLSession(configuration: config)
    }()

    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()
    private static let lock = NSLock()
    /// URLs the server said no to (a 404, a stand-in), with when — without it a
    /// dead jacket is re-asked on every redraw of a shelf. The list is kept on
    /// disk but lives a day: a shelf of books with dead cover ids would
    /// otherwise re-ask every URL on every cold start, and a day is long
    /// enough to matter without making a missed jacket unreachable for good.
    /// A fetch that never reached the server (offline, a timeout) is *not* a
    /// miss: it is asked again the next time the cover comes on screen.
    private static var missDates: [URL: TimeInterval] = [:]
    private static var missesLoaded = false
    private static let missTTL: TimeInterval = 24 * 3600
    private static let missStoreURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cover-misses.json")
    }()
    /// Fetches already under way — a grid asking for the same jacket makes
    /// one request, not one per cell.
    private static var inflight: [URL: Task<UIImage?, Never>] = [:]
    /// Below this the "cover" is a stand-in (a 1×1 tracking gif, an error
    /// image): counted as a miss so the next URL in the chain is tried.
    private static let minPixels: CGFloat = 40
    /// Jackets are drawn at most a few hundred points wide; a 1500px Open
    /// Library "-L" decoded whole is 6 MB a cell. ImageIO downsamples from the
    /// encoded bytes, so the full decode never happens.
    private static let maxPixels = 800

    static func image(from url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if isMiss(url) { return nil }
        lock.lock()
        if let task = inflight[url] {
            lock.unlock()
            return await task.value
        }
        let task = Task<UIImage?, Never> { await fetch(url) }
        inflight[url] = task
        lock.unlock()
        let image = await task.value
        lock.lock()
        inflight[url] = nil
        lock.unlock()
        return image
    }

    /// Warm the caches for jackets about to scroll on screen — the same
    /// single-flight fetch at utility priority, so a cell that appears asks
    /// the shared in-flight task, never a second request.
    static func prefetch(_ urls: [URL]) {
        for url in urls {
            Task.detached(priority: .utility) { _ = await image(from: url) }
        }
    }

    /// True when the server already said no to this jacket, recently enough to
    /// trust the answer; an entry past its day is dropped and the url retried.
    private static func isMiss(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadMisses()
        guard let at = missDates[url] else { return false }
        if Date().timeIntervalSince1970 - at < missTTL { return true }
        missDates[url] = nil
        return false
    }

    private static func rememberMiss(_ url: URL) {
        lock.lock()
        loadMisses()
        missDates[url] = Date().timeIntervalSince1970
        let snapshot = missDates
        lock.unlock()
        Task.detached(priority: .utility) { saveMisses(snapshot) }
    }

    /// The stored list, once a run, entries past their day already out. Call
    /// it holding the lock.
    private static func loadMisses() {
        guard !missesLoaded else { return }
        missesLoaded = true
        guard let data = try? Data(contentsOf: missStoreURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: TimeInterval]
        else { return }
        let now = Date().timeIntervalSince1970
        missDates = raw.reduce(into: [:]) { out, pair in
            if let url = URL(string: pair.key), now - pair.value < missTTL {
                out[url] = pair.value
            }
        }
    }

    private static func saveMisses(_ snapshot: [URL: TimeInterval]) {
        let raw = snapshot.reduce(into: [String: TimeInterval]()) { $0[$1.key.absoluteString] = $1.value }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: missStoreURL, options: .atomic)
    }

    private static func fetch(_ url: URL) async -> UIImage? {
        // no reply at all: nothing learned about the jacket, so nothing remembered
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = decode(data)
        else {
            rememberMiss(url)
            return nil
        }
        memory.setObject(image, forKey: url as NSURL, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return image
    }

    /// A downsampled decode, or nil for a stand-in too small to be a cover.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let header = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = header[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = header[kCGImagePropertyPixelHeight] as? CGFloat,
              width >= minPixels, height >= minPixels,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The first URL that answers with a real picture.
    static func firstImage(in urls: [URL]) async -> UIImage? {
        for url in urls where !Task.isCancelled {
            if let image = await image(from: url) { return image }
        }
        return nil
    }
}

/// Every remote cover on screen. Sized by its caller (`.frame` + clip), the
/// way the old `AsyncImage` blocks were: art fills what it is given, the
/// placeholder sits under it while loading and stands in when nothing loads.
struct RemoteCover: View {
    /// Best guess first, fallbacks after — order is the fallback chain.
    let urls: [URL]
    var icon: String = "book.closed"
    /// `.fill` crops to the box the way cells want; `.fit` keeps a whole jacket for previews.
    var contentMode: ContentMode = .fill
    /// Told the image that answered, when the caller wants it (a backdrop tint).
    var onLoad: ((UIImage) -> Void)? = nil
    @State private var image: UIImage?
    @State private var finished = false

    init(urls: [URL], icon: String = "book.closed",
         contentMode: ContentMode = .fill, onLoad: ((UIImage) -> Void)? = nil) {
        self.urls = urls
        self.icon = icon
        self.contentMode = contentMode
        self.onLoad = onLoad
    }

    init(url: URL?, icon: String = "book.closed",
         contentMode: ContentMode = .fill, onLoad: ((UIImage) -> Void)? = nil) {
        self.init(urls: url.map { [$0] } ?? [], icon: icon, contentMode: contentMode, onLoad: onLoad)
    }

    var body: some View {
        // The flat colour is the base and the art an overlay on it: an overlay never changes its base's
        // size, so a jacket that is not quite 2:3 is cropped to the box instead of pushing the box
        // wider — a `scaledToFill` image on its own reports its overflowing size to a grid.
        // a fitted jacket stands on its own; the grey is for the box an image fills (or hasn't yet)
        Color.secondary.opacity(image != nil && contentMode == .fit ? 0 : 0.15)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if finished {
                    Image(systemName: icon).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: urls) {
                finished = false
                image = await CoverFetch.firstImage(in: urls)
                finished = true
                if let image { onLoad?(image) }
            }
            .accessibilityHidden(true)
    }
}
