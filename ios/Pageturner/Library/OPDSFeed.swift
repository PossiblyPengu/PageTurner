import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// An OPDS catalogue page — the Atom kind a Calibre content server, Project Gutenberg and most
/// open libraries speak, and the JSON kind OPDS 2 catalogues (Standard Ebooks, SimplyE) answer
/// with. Pure parsing — no network — so it can be checked off-device.
struct OPDSFeed: Equatable {
    var title = ""
    var entries: [OPDSEntry] = []
    /// The next page of a long listing.
    var next: URL?
    /// A search URL with `{searchTerms}` in it, when the catalogue has a search.
    var searchTemplate: String?
    /// An OpenSearch description to fetch for the template, when the feed only points at one.
    var searchDescription: URL?
}

struct OPDSEntry: Equatable, Identifiable {
    var id: String
    var title = ""
    var author = ""
    var summary = ""
    var cover: URL?
    /// A listing to open (a shelf, an author, a letter).
    var navigation: URL?
    /// Files the entry offers, best first.
    var downloads: [OPDSDownload] = []
}

struct OPDSDownload: Equatable {
    var url: URL
    /// The MIME type the feed gave.
    var type: String

    /// The extension the saved file gets, from the type or the address.
    var fileExtension: String {
        let t = type.lowercased()
        if t.contains("epub") { return "epub" }
        if t.contains("pdf") { return "pdf" }
        if t.contains("comicbook+zip") || t.contains("cbz") { return "cbz" }
        if t.contains("m4b") || t.contains("mp4") || t.contains("m4a") { return "m4b" }
        if t.contains("mpeg") || t.contains("mp3") { return "mp3" }
        if t.contains("text/plain") { return "txt" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "epub" : ext
    }

    /// Formats the library can open, in the order worth taking.
    static let preferred = ["epub", "pdf", "cbz", "m4b", "mp3", "txt"]
}

enum OPDS {
    /// With namespaces off the parser hands over the qualified name — a feed writing
    /// `<atom:entry>` still means an entry: compare the local part.
    static func local(_ name: String) -> String {
        name.components(separatedBy: ":").last ?? name
    }

    /// Parse a feed. `base` resolves the relative links it carries. An OPDS 2 catalogue
    /// answers in JSON; the older kind is an Atom page.
    static func parse(_ data: Data, base: URL) -> OPDSFeed? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == 0x7B { // "{"
            return parseJSON(data, base: base)
        }
        let delegate = FeedParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard delegate.sawFeed else { return nil }
        return delegate.feed
    }

    /// The search address in an OpenSearch description document.
    static func searchTemplate(fromDescription data: Data) -> String? {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.template
    }

    /// The search URL for `terms`, percent-encoded into the template.
    static func searchURL(template: String, terms: String, base: URL) -> URL? {
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? terms
        let filled = template
            .replacingOccurrences(of: "{searchTerms}", with: encoded)
            .replacingOccurrences(of: "{startPage?}", with: "1")
            .replacingOccurrences(of: "{startIndex?}", with: "0")
            .replacingOccurrences(of: "{count?}", with: "50")
        // any optional {x?} parameter left over means nothing
        let cleaned = filled.replacingOccurrences(of: "\\{[^}]*\\?\\}", with: "", options: .regularExpression)
        return URL(string: cleaned, relativeTo: base)?.absoluteURL
    }

    /// A search link's template: kept decoded, resolved against the page it came from.
    private static func resolvedTemplate(_ href: String, base: URL) -> String {
        let decoded = href.removingPercentEncoding ?? href
        guard let url = URL(string: decoded, relativeTo: base)?.absoluteURL else { return decoded }
        return url.absoluteString.removingPercentEncoding ?? url.absoluteString
    }

    /// Best format first — the order the rows in a listing show.
    private static func rank(_ d: OPDSDownload) -> Int {
        OPDSDownload.preferred.firstIndex(of: d.fileExtension) ?? OPDSDownload.preferred.count
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        let base: URL
        var feed = OPDSFeed()
        var sawFeed = false

        private var path: [String] = []
        private var text = ""
        private var entry: OPDSEntry?
        /// A summary can hold markup of its own: everything inside it is its text.
        private var summaryDepth = 0
        private var summaryText = ""

        init(base: URL) { self.base = base }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = OPDS.local(name)
            path.append(name)
            text = ""
            if summaryDepth > 0 {
                summaryDepth += 1
            } else if entry != nil, name == "summary" || name == "content" {
                summaryDepth = 1
                summaryText = ""
            }
            switch name {
            case "feed": sawFeed = true
            case "entry": entry = OPDSEntry(id: UUID().uuidString)
            case "link": link(attributes)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if summaryDepth > 0 { summaryText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let chunk = String(data: CDATABlock, encoding: .utf8) ?? ""
            text += chunk
            if summaryDepth > 0 { summaryText += chunk }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let name = OPDS.local(name)
            defer { path.removeLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let inEntry = entry != nil
            if summaryDepth > 0 {
                summaryDepth -= 1
                if summaryDepth == 0, inEntry, entry?.summary.isEmpty == true {
                    entry?.summary = Self.plain(summaryText)
                }
                return
            }
            switch name {
            case "title":
                if inEntry { entry?.title = value } else if path.count == 2 { feed.title = value }
            case "id":
                if inEntry, !value.isEmpty { entry?.id = value }
            case "name":
                if var current = entry, path.dropLast().last == "author", !value.isEmpty {
                    current.author = current.author.isEmpty ? value : current.author + " & " + value
                    entry = current
                }
            case "entry":
                if var finished = entry {
                    finished.downloads.sort { OPDS.rank($0) < OPDS.rank($1) }
                    feed.entries.append(finished)
                }
                entry = nil
            default: break
            }
        }

        private func link(_ a: [String: String]) {
            guard let href = a["href"], !href.isEmpty,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { return }
            let rel = (a["rel"] ?? "").lowercased()
            let type = (a["type"] ?? "").lowercased()
            if entry != nil {
                if rel.contains("opds-spec.org/acquisition") {
                    // a store's "buy" or "sample" is not a file we can have
                    if rel.hasSuffix("/buy") || rel.hasSuffix("/sample") || rel.hasSuffix("/subscribe") { return }
                    let download = OPDSDownload(url: url, type: type)
                    if OPDSDownload.preferred.contains(download.fileExtension) { entry?.downloads.append(download) }
                } else if rel.contains("image/thumbnail") || rel.hasSuffix("/thumbnail") {
                    if entry?.cover == nil { entry?.cover = url }
                } else if rel.contains("opds-spec.org/image") {
                    if entry?.cover == nil { entry?.cover = url }
                } else if type.contains("atom+xml"), entry?.navigation == nil,
                          rel.isEmpty || rel == "subsection" || rel == "alternate" || rel.contains("sort/") || rel.contains("crawlable") || rel.contains("related") || rel == "http://opds-spec.org/shelf" {
                    entry?.navigation = url
                }
            } else {
                if rel == "next" { feed.next = url }
                if rel == "search" {
                    if href.contains("{searchTerms}") || href.removingPercentEncoding?.contains("{searchTerms}") == true {
                        feed.searchTemplate = OPDS.resolvedTemplate(href, base: base)
                    } else if type.contains("opensearchdescription") {
                        feed.searchDescription = url
                    }
                }
            }
        }

        /// A summary can carry HTML.
        private static func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var template: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard OPDS.local(name) == "Url", template == nil, let t = attributes["template"],
                  (attributes["type"] ?? "").contains("atom") else { return }
            template = t
        }
    }

    // MARK: - OPDS 2 (JSON)

    /// A JSON field that may be a string, a list, or an object carrying `name` — OPDS 2
    /// lets `rel`, `title` and `author` come in any of those shapes.
    private enum JSONValue: Decodable {
        case string(String), array([JSONValue]), object([String: JSONValue]), other

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
            if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
            self = .other
        }

        /// The one string it means: itself, a `name` field, or the first it holds.
        var text: String? {
            switch self {
            case .string(let s): return s
            case .object(let o): return o["name"]?.text ?? o.values.lazy.compactMap(\.text).first
            case .array(let a): return a.lazy.compactMap(\.text).first
            case .other: return nil
            }
        }

        /// Every string it carries — rel values, author names.
        var texts: [String] {
            switch self {
            case .string(let s): return [s]
            case .object(let o): return o["name"].map(\.texts) ?? o.values.flatMap(\.texts)
            case .array(let a): return a.flatMap(\.texts)
            case .other: return []
            }
        }
    }

    private struct JSONFeed: Decodable {
        var metadata: JSONMeta?
        var links: [JSONLink]?
        var navigation: [JSONLink]?
        var facets: [JSONFacet]?
        var groups: [JSONGroup]?
        var publications: [JSONPublication]?
    }

    private struct JSONMeta: Decodable {
        var title: JSONValue?
        var identifier: String?
        var author: JSONValue?
        var description: JSONValue?
    }

    private struct JSONLink: Decodable {
        var rel: JSONValue?
        var href: String?
        var title: JSONValue?
        var type: String?
        var height: Int?
        var width: Int?

        // a hand-written init(from:) is all the conformance needs, so the compiler
        // never synthesizes a CodingKeys of its own for it
        private enum CodingKeys: String, CodingKey {
            case rel, href, title, type, height, width
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rel = try? c.decode(JSONValue.self, forKey: .rel)
            href = try? c.decode(String.self, forKey: .href)
            title = try? c.decode(JSONValue.self, forKey: .title)
            type = try? c.decode(String.self, forKey: .type)
            // dimensions come as numbers in the spec, strings in the wild — take both
            height = (try? c.decode(Int.self, forKey: .height)) ?? Int((try? c.decode(String.self, forKey: .height)) ?? "")
            width = (try? c.decode(Int.self, forKey: .width)) ?? Int((try? c.decode(String.self, forKey: .width)) ?? "")
        }
    }

    private struct JSONFacet: Decodable {
        var metadata: JSONMeta?
        var links: [JSONLink]?
    }

    private struct JSONGroup: Decodable {
        var metadata: JSONMeta?
        var navigation: [JSONLink]?
        var publications: [JSONPublication]?
        var links: [JSONLink]?
    }

    private struct JSONPublication: Decodable {
        var metadata: JSONMeta?
        var links: [JSONLink]?
        var images: [JSONLink]?
    }

    private static func parseJSON(_ data: Data, base: URL) -> OPDSFeed? {
        guard let root = try? JSONDecoder().decode(JSONFeed.self, from: data) else { return nil }
        // a JSON object that is not a feed at all decodes to nothing either
        guard root.metadata != nil || root.links != nil || root.navigation != nil || root.publications != nil
        else { return nil }
        var feed = OPDSFeed()
        feed.title = root.metadata?.title?.text ?? ""
        for link in root.links ?? [] {
            let rels = (link.rel?.texts ?? []).map { $0.lowercased() }
            guard let href = link.href else { continue }
            if rels.contains("next"), let url = URL(string: href, relativeTo: base)?.absoluteURL { feed.next = url }
            if rels.contains("search"), href.contains("{searchTerms}") {
                feed.searchTemplate = resolvedTemplate(href, base: base)
            }
        }
        feed.entries = jsonEntries(
            navigation: root.navigation ?? [], facets: root.facets ?? [],
            groups: root.groups ?? [], publications: root.publications ?? [], base: base)
        return feed
    }

    /// Navigation listings, facet links, groups and books — OPDS 2 keeps them in separate
    /// arrays; a page's rows are all entries here, listings first.
    private static func jsonEntries(
        navigation: [JSONLink], facets: [JSONFacet], groups: [JSONGroup],
        publications: [JSONPublication], base: URL
    ) -> [OPDSEntry] {
        var entries: [OPDSEntry] = []
        func listing(_ link: JSONLink) {
            guard let href = link.href, let url = URL(string: href, relativeTo: base)?.absoluteURL else { return }
            var entry = OPDSEntry(id: url.absoluteString)
            entry.title = link.title?.text ?? url.lastPathComponent
            entry.navigation = url
            entries.append(entry)
        }
        navigation.forEach(listing)
        for facet in facets { (facet.links ?? []).forEach(listing) }
        for group in groups {
            (group.navigation ?? []).forEach(listing)
            (group.links ?? []).forEach(listing)
            entries += jsonEntries(
                navigation: [], facets: [], groups: [], publications: group.publications ?? [], base: base)
        }
        for pub in publications { entries.append(jsonPublication(pub, base: base)) }
        return entries
    }

    private static func jsonPublication(_ pub: JSONPublication, base: URL) -> OPDSEntry {
        var entry = OPDSEntry(id: pub.metadata?.identifier ?? UUID().uuidString)
        let meta = pub.metadata
        entry.title = meta?.title?.text ?? ""
        entry.author = (meta?.author?.texts ?? []).joined(separator: " & ")
        entry.summary = meta?.description?.text ?? ""
        // the smallest image worth a thumbnail box, else whatever was offered
        let images = (pub.images ?? []).compactMap { image -> (URL, Int)? in
            guard let href = image.href, let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
            return (url, image.height ?? Int.max)
        }.sorted { $0.1 < $1.1 }
        entry.cover = (images.first { $0.1 >= 64 } ?? images.first)?.0
        var selfURL: URL?
        for link in pub.links ?? [] {
            let rels = (link.rel?.texts ?? []).map { $0.lowercased() }
            guard let href = link.href, let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            if rels.contains("self") { selfURL = url; continue }
            guard rels.contains(where: { $0.contains("acquisition") }) else { continue }
            let download = OPDSDownload(url: url, type: (link.type ?? "").lowercased())
            if OPDSDownload.preferred.contains(download.fileExtension) { entry.downloads.append(download) }
        }
        entry.downloads.sort { rank($0) < rank($1) }
        // a book in a format the library can't open is still a page to look at
        if entry.downloads.isEmpty { entry.navigation = selfURL }
        return entry
    }
}
