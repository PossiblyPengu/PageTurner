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
    /// URLs the server said no to (a 404, a stand-in) this run — without it a
    /// dead jacket is re-asked on every redraw of a shelf. A fetch that never
    /// reached the server (offline, a timeout) is *not* a miss: it is asked
    /// again the next time the cover comes on screen.
    private static var misses: Set<URL> = []
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
        lock.lock()
        if misses.contains(url) { lock.unlock(); return nil }
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

    private static func fetch(_ url: URL) async -> UIImage? {
        // no reply at all: nothing learned about the jacket, so nothing remembered
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = decode(data)
        else {
            lock.lock()
            misses.insert(url)
            lock.unlock()
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
    @State private var image: UIImage?
    @State private var finished = false

    init(urls: [URL], icon: String = "book.closed") {
        self.urls = urls
        self.icon = icon
    }

    init(url: URL?, icon: String = "book.closed") {
        self.init(urls: url.map { [$0] } ?? [], icon: icon)
    }

    var body: some View {
        // The flat colour is the base and the art an overlay on it: an overlay never changes its base's
        // size, so a jacket that is not quite 2:3 is cropped to the box instead of pushing the box
        // wider — a `scaledToFill` image on its own reports its overflowing size to a grid.
        Color.secondary.opacity(0.15)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
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
            }
            .accessibilityHidden(true)
    }
}
