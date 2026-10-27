import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// FictionBook 2 (`.fb2`, or `.fbz` zipped) — the XML e-book format of Russian and Eastern European libraries —
/// read into the HTML that `TextBook` already turns into an EPUB. Its sections become chapters (a part's chapters
/// chapters of their own), poems and epigraphs quotes, the notes body a Notes chapter at the end, and the title,
/// authors, language, blurb and cover come from its own description. Pure Foundation (plus FoundationXML on
/// Linux), so it is checked off-device.
enum FB2Book {
    struct Parsed {
        var title: String
        var authors: [String]
        var language: String
        /// The blurb (`annotation`), as plain text.
        var annotation: String
        /// A whole HTML document: the main body, then the notes.
        var html: String
        var cover: TextBook.Cover?
    }

    static func parse(_ data: Data) -> Parsed? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        let finished = parser.parse()
        // a file broken near its end still has a book in it; one with no body does not
        guard finished || !reader.main.isEmpty, !reader.main.isEmpty || !reader.notes.isEmpty else { return nil }
        var html = "<html><head><title>\(TextBook.esc(reader.title))</title></head><body>\n" + reader.main
        if !reader.notes.isEmpty {
            let heading = reader.notesTitle.isEmpty ? "Notes" : reader.notesTitle
            html += "<h1>\(TextBook.esc(heading))</h1>\n" + reader.notes
        }
        html += "</body></html>"
        return Parsed(
            title: collapse(reader.title), authors: reader.authors, language: collapse(reader.language),
            annotation: collapse(reader.annotation), html: html, cover: reader.cover)
    }

    fileprivate static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The streaming reader. Element names are taken without a namespace prefix (`l:href`, `xlink:href` alike).
    private final class Reader: NSObject, XMLParserDelegate {
        var title = ""
        var authors: [String] = []
        var language = ""
        var annotation = ""
        var main = ""
        var notes = ""
        var notesTitle = ""
        var cover: TextBook.Cover?

        private var stack: [String] = []
        private var coverID: String?
        private var author: (first: String, middle: String, last: String, nick: String) = ("", "", "", "")
        /// Which body is being written: the main one, or the notes.
        private var inNotes = false
        private var sectionDepth = 0
        /// A title being gathered — its lines join into one heading.
        private var titleLines: [String]?
        private var titleLine = ""
        /// The cover's base64, while its `binary` is being read.
        private var binary: (id: String, type: String, text: String)?

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        private func has(_ name: String) -> Bool { stack.contains(name) }

        private var inTitleInfo: Bool { has("title-info") && !has("src-title-info") }

        private func emit(_ s: String) {
            if titleLines != nil { return }
            if inNotes { notes += s } else { main += s }
        }

        private func href(_ attributes: [String: String]) -> String? {
            attributes.first { local($0.key) == "href" }?.value
        }

        // MARK: Elements

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            let name = local(elementName)
            stack.append(name)
            if has("description") {
                if name == "author", inTitleInfo { author = ("", "", "", "") }
                if name == "image", has("coverpage"), inTitleInfo, let ref = href(attributes) {
                    coverID = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
                }
                return
            }
            switch name {
            case "body":
                inNotes = attributes["name"] == "notes" || attributes["name"] == "comments"
                sectionDepth = 0
            case "section":
                sectionDepth += 1
            case "title":
                titleLines = []
                titleLine = ""
            case "p", "v", "subtitle", "text-author":
                if titleLines != nil { titleLine = ""; return }
                switch name {
                case "subtitle": emit("<h4>")
                case "text-author": emit("<p><em>")
                default: emit("<p>")
                }
            case "poem", "epigraph", "cite":
                emit("<blockquote>")
            case "emphasis": emit("<em>")
            case "strong": emit("<strong>")
            case "strikethrough": emit("<del>")
            case "sub": emit("<sub>")
            case "sup": emit("<sup>")
            case "code": emit("<code>")
            case "a":
                // a note's number reads as a superscript; an outside link stays a link
                if let ref = href(attributes), ref.hasPrefix("http://") || ref.hasPrefix("https://") {
                    emit("<a href=\"\(TextBook.esc(ref))\">")
                    stack[stack.count - 1] = "a-link"
                } else if attributes["type"] == "note" {
                    emit("<sup>")
                    stack[stack.count - 1] = "a-note"
                }
            case "binary":
                if let id = attributes["id"], id == coverID {
                    binary = (id, attributes["content-type"] ?? "image/jpeg", "")
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            let name = stack.popLast() ?? local(elementName)
            if has("description") || name == "description" {
                // paragraphs of the blurb keep a space between them
                if name == "p", has("annotation"), inTitleInfo { annotation += " " }
                if name == "author", inTitleInfo {
                    let full = [author.first, author.middle, author.last].map(FB2Book.collapse).filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let named = full.isEmpty ? FB2Book.collapse(author.nick) : full
                    if !named.isEmpty { authors.append(named) }
                }
                return
            }
            switch name {
            case "section":
                sectionDepth = max(0, sectionDepth - 1)
            case "title":
                guard var lines = titleLines else { return }
                // a title written without paragraphs
                if !FB2Book.collapse(titleLine).isEmpty { lines.append(FB2Book.collapse(titleLine)) }
                titleLine = ""
                titleLines = nil
                let heading = Self.joinTitle(lines)
                guard !heading.isEmpty else { return }
                if inNotes {
                    // a note's number, or the notes body's own heading
                    if sectionDepth == 0 { notesTitle = heading } else { emit("<p><strong>\(TextBook.esc(heading))</strong></p>\n") }
                } else {
                    let level = sectionDepth == 0 ? 3 : min(sectionDepth, 3)
                    emit("<h\(level)>\(TextBook.esc(heading))</h\(level)>\n")
                }
            case "p", "v", "subtitle", "text-author":
                if titleLines != nil {
                    let line = FB2Book.collapse(titleLine)
                    if !line.isEmpty { titleLines?.append(line) }
                    titleLine = ""
                    return
                }
                switch name {
                case "subtitle": emit("</h4>\n")
                case "text-author": emit("</em></p>\n")
                default: emit("</p>\n")
                }
            case "poem", "epigraph", "cite":
                emit("</blockquote>\n")
            case "emphasis": emit("</em>")
            case "strong": emit("</strong>")
            case "strikethrough": emit("</del>")
            case "sub": emit("</sub>")
            case "sup": emit("</sup>")
            case "code": emit("</code>")
            case "a-link": emit("</a>")
            case "a-note": emit("</sup>")
            case "binary":
                if let binary, let data = Data(base64Encoded: binary.text, options: .ignoreUnknownCharacters), !data.isEmpty {
                    cover = TextBook.Cover(data: data, mediaType: binary.type)
                }
                binary = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if binary != nil { binary?.text += string; return }
            guard let top = stack.last else { return }
            if has("description") {
                guard inTitleInfo else { return }
                if has("annotation") { annotation += string; return }
                switch top {
                case "book-title": title += string
                case "lang": language += string
                case "first-name" where has("author"): author.first += string
                case "middle-name" where has("author"): author.middle += string
                case "last-name" where has("author"): author.last += string
                case "nickname" where has("author"): author.nick += string
                default: break
                }
                return
            }
            guard has("body") else { return }
            if titleLines != nil { titleLine += string; return }
            emit(TextBook.esc(string))
        }

        /// "Chapter 1" and "The Start" read as "Chapter 1. The Start"; a line that ends in its own stop keeps it.
        static func joinTitle(_ lines: [String]) -> String {
            var out = ""
            for line in lines {
                if out.isEmpty { out = line; continue }
                out += ".!?:;—…".contains(out.last ?? " ") ? " " + line : ". " + line
            }
            return out
        }
    }
}
