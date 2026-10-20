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
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Pageturner/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") cover-fetch"]
        return URLSession(configuration: config)
    }()

    private static let memory = NSCache<NSURL, UIImage>()
    /// URLs that failed this run — without it a dead jacket is re-asked on
    /// every redraw of a shelf. Kept in memory only: a network hiccup clears
    /// on relaunch.
    private static let misses = NSMutableSet()
    /// Below this the "cover" is a stand-in (a 1×1 tracking gif, an error
    /// image): counted as a miss so the next URL in the chain is tried.
    private static let minPixels: CGFloat = 40

    static func image(from url: URL) async -> UIImage? {
        let key = url as NSURL
        if let hit = memory.object(forKey: key) { return hit }
        if misses.contains(key) { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = UIImage(data: data),
              let size = image.cgImage.map({ CGSize(width: $0.width, height: $0.height) }),
              size.width >= minPixels, size.height >= minPixels
        else {
            misses.add(key)
            return nil
        }
        memory.setObject(image, forKey: key)
        return image
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
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
                if finished {
                    Image(systemName: icon).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
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
