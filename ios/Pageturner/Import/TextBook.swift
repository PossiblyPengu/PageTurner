import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Turns plain text, Markdown and HTML into an EPUB, so Readium — which only
/// opens publications — reads them with the same themes, search, highlights and
/// read-aloud as any other book. Pure Foundation (plus NaturalLanguage when it
/// is there), so it can be exercised on Linux.
///
/// Plain text gets paragraphs un-wrapped, chapters found from headings
/// ("Chapter 3", "PART ONE", ALL-CAPS lines) and Project Gutenberg's header and
/// licence trimmed. Markdown is parsed into real headings, lists and quotes.
/// HTML is rebuilt as well-formed XHTML from a whitelist of tags.
enum TextBook {
    enum Format { case plain, markdown, html, fb2 }

    /// A cover picture to put in the EPUB (an FB2's own).
    struct Cover {
        var data: Data
        var mediaType: String

        var fileExtension: String {
            switch mediaType.lowercased() {
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            default: return "jpg"
            }
        }
    }

    struct Converted {
        var title: String
        var author: String
        var language: String
        var epub: Data
        var chapterCount: Int
        /// Where each page of a PDF begins, for a text version made with page marks (`PDFText.html(markPages:)`).
        var pageSpots: [PDFText.PageSpot] = []
    }

    /// One chapter. `body` is an XHTML fragment that already carries its heading.
    struct Section {
        var title: String
        var body: String
    }

    private struct Meta {
        var title = ""
        var author = ""
    }

    /// Which converter, if any, an extension belongs to.
    static func format(forExtension ext: String) -> Format? {
        switch ext.lowercased() {
        case "txt", "text": return .plain
        case "md", "markdown", "mdown": return .markdown
        case "html", "htm", "xhtml": return .html
        case "fb2": return .fb2
        default: return nil
        }
    }

    // MARK: - Entry point

    static func convert(
        _ data: Data, format: Format, fallbackTitle: String, now: Date = Date()
    ) -> Converted? {
        var meta = Meta()
        var sections: [Section]
        var language: String
        var cover: Cover?
        var summary = ""
        if format == .fb2 {
            // XML that names its own encoding: parsed from the bytes, not decoded first
            guard let book = FB2Book.parse(data) else { return nil }
            (sections, meta) = htmlSections(book.html)
            if !book.title.isEmpty { meta.title = book.title }
            meta.author = book.authors.joined(separator: ", ")
            language = book.language.isEmpty ? detectLanguage(BookText.plain(fromHTML: book.html)) : book.language
            cover = book.cover
            summary = book.annotation
        } else {
            let text = decode(data)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            switch format {
            case .plain: (sections, meta) = plainSections(text)
            case .markdown: (sections, meta) = markdownSections(text)
            case .html, .fb2: (sections, meta) = htmlSections(text)
            }
            language = detectLanguage(text)
        }
        guard !sections.isEmpty else { return nil }

        let fallback = fallbackTitle
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = meta.title.isEmpty ? (fallback.isEmpty ? "Untitled" : fallback) : meta.title
        for i in sections.indices where sections[i].title.isEmpty {
            sections[i].title = sections.count == 1 ? title : "Part \(i + 1)"
        }
        let spots = takePageMarks(&sections)
        let epub = buildEPUB(
            title: title, author: meta.author, language: language, sections: sections, now: now,
            cover: cover, summary: summary)
        return Converted(
            title: title, author: meta.author, language: language, epub: epub,
            chapterCount: sections.count, pageSpots: spots)
    }

    /// A PDF's page marks taken out of the chapters, and where each sat: how far through its chapter's words.
    static func takePageMarks(_ sections: inout [Section]) -> [PDFText.PageSpot] {
        let open = String(PDFText.markOpen), close = String(PDFText.markClose)
        guard sections.contains(where: { $0.body.contains(open) }) else { return [] }
        guard let mark = try? NSRegularExpression(pattern: open + "([0-9]+)" + close) else { return [] }
        var spots: [PDFText.PageSpot] = []
        for i in sections.indices where sections[i].body.contains(open) {
            let body = sections[i].body
            // offsets are counted in the chapter's words, not its markup
            let words = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) as NSString
            let found = mark.matches(in: words as String, range: NSRange(location: 0, length: words.length))
            let total = words.length - found.reduce(0) { $0 + $1.range.length }
            var removed = 0
            for match in found {
                let page = Int(words.substring(with: match.range(at: 1))) ?? 0
                let at = match.range.location - removed
                removed += match.range.length
                spots.append(PDFText.PageSpot(page: page, chapter: i,
                                              progression: total > 0 ? Double(at) / Double(total) : 0))
            }
            sections[i].body = mark.stringByReplacingMatches(
                in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        }
        return spots
    }

    // MARK: - Decoding

    /// UTF-8 (with or without a BOM), UTF-16 with a BOM, else Windows-1252 /
    /// Latin-1 — the encodings plain-text books actually arrive in.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func detectLanguage(_ text: String) -> String {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        if let language = recognizer.dominantLanguage, language != .undetermined {
            return language.rawValue
        }
        #endif
        return "en"
    }

    // MARK: - XML helpers

    /// Escape for XML text/attributes, dropping characters XML 1.0 can't carry.
    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(scalar)
            case 0x00...0x1F, 0xFFFE, 0xFFFF: continue
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // patterns are literals in this file; a bad one is a bug the Linux check catches
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func firstMatch(_ r: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let range = m.range(at: i)
        guard range.location != NSNotFound, let r = Range(range, in: s) else { return nil }
        return String(s[r])
    }

    private static func replacing(_ r: NSRegularExpression, in s: String, with template: String) -> String {
        r.stringByReplacingMatches(
            in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Plain text

    private static let strongHeading = rx(
        #"^(chapter|chap\.|part|book|section|act|canto|letter|volume|vol\.)\s+([0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b[\s.:\-—–]*.{0,60}$"#,
        .caseInsensitive)
    private static let namedHeading = rx(
        #"^(prologue|epilogue|preface|foreword|introduction|afterword|appendix|acknowledg(e)?ments|dedication|prelude|interlude|conclusion)\b[\s.:\-—–]*.{0,40}$"#,
        .caseInsensitive)

    /// A paragraph that is really a chapter heading: one to three short lines
    /// whose first line reads "Chapter 3", "PART ONE", "Epilogue"…
    private static func headingText(_ lines: [String]) -> String? {
        guard let first = lines.first, lines.count <= 3, first.count <= 70 else { return nil }
        let joined = lines.joined(separator: " — ")
        guard joined.count <= 90 else { return nil }
        let isHeading = firstMatch(strongHeading, in: first) != nil || firstMatch(namedHeading, in: first) != nil
        return isHeading ? joined : nil
    }

    /// A short ALL-CAPS line standing alone — a weaker sign of a heading.
    private static func allCapsHeading(_ lines: [String]) -> String? {
        guard lines.count == 1, let line = lines.first, line.count >= 3, line.count <= 50 else { return nil }
        guard line.rangeOfCharacter(from: .lowercaseLetters) == nil,
              line.filter({ $0.isLetter }).count >= 3,
              !(line.hasSuffix(",") || line.hasSuffix(";")) else { return nil }
        return line
    }

    /// Verse keeps its line breaks: several short lines that each start with a capital.
    private static func isVerse(_ lines: [String]) -> Bool {
        guard lines.count >= 3 else { return false }
        let average = Double(lines.reduce(0) { $0 + $1.count }) / Double(lines.count)
        let capitals = lines.filter { $0.first?.isUppercase ?? false }.count
        return average < 45 && Double(capitals) / Double(lines.count) >= 0.7
    }

    private static func renderParagraph(_ lines: [String]) -> String {
        if isVerse(lines) {
            return "<p class=\"verse\">" + lines.map { esc($0) }.joined(separator: "<br/>\n") + "</p>"
        }
        return "<p>" + esc(collapseSpaces(lines.joined(separator: " "))) + "</p>"
    }

    /// Project Gutenberg files wrap the book in a licence; read the title and
    /// author from the header and keep only what is between the markers.
    private static func stripGutenberg(_ text: String, meta: inout Meta) -> String {
        let head = String(text.prefix(5000))
        if let m = firstMatch(rx(#"(?m)^Title:\s*(.+?)\s*$"#), in: head), let t = group(m, 1, in: head) {
            meta.title = t
        }
        if let m = firstMatch(rx(#"(?m)^Author:\s*(.+?)\s*$"#), in: head), let a = group(m, 1, in: head) {
            meta.author = a
        }
        var t = text
        if let m = firstMatch(rx(#"\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG[^\n]*\n"#, .caseInsensitive), in: t),
           let r = Range(m.range, in: t) {
            t = String(t[r.upperBound...])
        }
        if let m = firstMatch(rx(#"\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG"#, .caseInsensitive), in: t),
           let r = Range(m.range, in: t) {
            t = String(t[..<r.lowerBound])
        }
        return t
    }

    private static func plainSections(_ raw: String) -> ([Section], Meta) {
        var meta = Meta()
        let text = stripGutenberg(normalize(raw), meta: &meta)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let nonBlank = lines.filter { !$0.isEmpty }.count
        let blank = lines.count - nonBlank

        // Paragraphs: blank-line separated (and un-wrapped), or — when a file
        // has almost no blank lines — one paragraph per line.
        var paragraphs: [[String]] = []
        if nonBlank > 40, Double(blank) / Double(max(nonBlank, 1)) < 0.04 {
            paragraphs = lines.filter { !$0.isEmpty }.map { [$0] }
        } else {
            var current: [String] = []
            for line in lines {
                if line.isEmpty {
                    if !current.isEmpty { paragraphs.append(current); current = [] }
                } else {
                    current.append(line)
                }
            }
            if !current.isEmpty { paragraphs.append(current) }
        }
        guard !paragraphs.isEmpty else { return ([], meta) }

        var headings: [String?] = paragraphs.map { headingText($0) }
        if headings.compactMap({ $0 }).count < 2 {
            let weak = paragraphs.map { allCapsHeading($0) }
            let weakCount = weak.compactMap { $0 }.count
            if (3...300).contains(weakCount) { headings = weak }
        }

        var sections: [Section] = []
        var title: String?
        var parts: [String] = []
        func flush() {
            guard title != nil || !parts.isEmpty else { return }
            let heading = title.map { "<h2>\(esc($0))</h2>\n" } ?? ""
            sections.append(Section(
                title: title ?? (sections.isEmpty ? "Beginning" : ""),
                body: heading + parts.joined(separator: "\n")))
            parts = []
        }
        for (paragraph, heading) in zip(paragraphs, headings) {
            if let heading {
                flush()
                title = heading
            } else {
                parts.append(renderParagraph(paragraph))
            }
        }
        flush()

        if sections.count == 1, sections[0].title == "Beginning" {
            // no chapters found: leave one section, or cut a very long book into parts
            return (chunk(paragraphs.map { renderParagraph($0) }), meta)
        }
        return (sections, meta)
    }

    /// Cut a long run of blocks into parts of ~40,000 characters so the
    /// contents list has somewhere to jump; a short text stays one section.
    private static func chunk(_ blocks: [String]) -> [Section] {
        let total = blocks.reduce(0) { $0 + $1.count }
        guard total > 80_000 else { return [Section(title: "", body: blocks.joined(separator: "\n"))] }
        var sections: [Section] = []
        var current: [String] = []
        var size = 0
        for block in blocks {
            current.append(block)
            size += block.count
            if size >= 40_000 {
                sections.append(Section(title: "Part \(sections.count + 1)", body: current.joined(separator: "\n")))
                current = []
                size = 0
            }
        }
        if !current.isEmpty {
            sections.append(Section(title: "Part \(sections.count + 1)", body: current.joined(separator: "\n")))
        }
        return sections
    }

    // MARK: - Markdown

    private struct Block {
        var level: Int?       // set for headings
        var text = ""         // a heading's plain text
        var html: String
    }

    private static func markdownSections(_ raw: String) -> ([Section], Meta) {
        var meta = Meta()
        var text = normalize(raw)
        if text.hasPrefix("---\n"),
           let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let front = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            for line in front.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                    value = String(value.dropFirst().dropLast())
                }
                if key == "title" { meta.title = value }
                if key == "author" || key == "authors" { meta.author = value }
            }
            text = String(text[end.upperBound...])
        }

        let blocks = markdownBlocks(text)
        guard !blocks.isEmpty else { return ([], meta) }
        let h1 = blocks.filter { $0.level == 1 }.count
        let h2 = blocks.filter { $0.level == 2 }.count
        if h1 == 1, meta.title.isEmpty, let heading = blocks.first(where: { $0.level == 1 }) {
            meta.title = heading.text
        }
        let splitLevel: Int? = h1 >= 2 ? 1 : (h2 >= 2 ? 2 : nil)
        guard let splitLevel else {
            return (chunk(blocks.map { $0.html }), meta)
        }

        var sections: [Section] = []
        var title = ""
        var parts: [String] = []
        func flush() {
            guard !parts.isEmpty else { return }
            sections.append(Section(title: title.isEmpty ? (sections.isEmpty ? "Beginning" : "") : title,
                                    body: parts.joined(separator: "\n")))
            parts = []
        }
        for block in blocks {
            if let level = block.level, level <= splitLevel {
                flush()
                title = block.text
            }
            parts.append(block.html)
        }
        flush()
        return (sections, meta)
    }

    private static let atx = rx(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let hr = rx(#"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#)
    private static let listItem = rx(#"^(\s{0,6})([-*+]|\d{1,9}[.)])\s+(.*)$"#)
    private static let setextEquals = rx(#"^=+\s*$"#)
    private static let setextDashes = rx(#"^-+\s*$"#)

    private static func startsNewBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return firstMatch(atx, in: line) != nil || firstMatch(hr, in: line) != nil
            || firstMatch(listItem, in: line) != nil || t.hasPrefix(">")
            || t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func markdownBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(Block(html: "<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>"))
                continue
            }
            // ATX heading
            if let m = firstMatch(atx, in: line), let hashes = group(m, 1, in: line) {
                let raw = group(m, 2, in: line) ?? ""
                let level = hashes.count
                blocks.append(Block(level: level, text: plain(raw),
                                    html: "<h\(level)>\(inline(raw))</h\(level)>"))
                i += 1; continue
            }
            // horizontal rule
            if firstMatch(hr, in: line) != nil {
                blocks.append(Block(html: "<hr/>")); i += 1; continue
            }
            // block quote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    } else if t.isEmpty { break } else { quoted.append(t) }
                    i += 1
                }
                var paragraphs: [String] = []
                var current: [String] = []
                for q in quoted {
                    if q.isEmpty { if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] } }
                    else { current.append(q) }
                }
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                let inner = paragraphs.map { "<p>\(inline($0))</p>" }.joined(separator: "\n")
                blocks.append(Block(html: "<blockquote>\n\(inner)\n</blockquote>"))
                continue
            }
            // list
            if let first = firstMatch(listItem, in: line), let marker = group(first, 2, in: line) {
                let ordered = marker.first?.isNumber ?? false
                var items: [String] = []
                while i < lines.count {
                    if let m = firstMatch(listItem, in: lines[i]), let body = group(m, 3, in: lines[i]) {
                        items.append(body)
                    } else if lines[i].hasPrefix("  "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !items.isEmpty {
                        items[items.count - 1] += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else { break }
                    i += 1
                }
                let tag = ordered ? "ol" : "ul"
                blocks.append(Block(html: "<\(tag)>\n" + items.map { "<li>\(inline($0))</li>" }.joined(separator: "\n") + "\n</\(tag)>"))
                continue
            }
            // setext heading ("Title" over "=====" or "-----")
            if i + 1 < lines.count {
                let next = lines[i + 1]
                if firstMatch(setextEquals, in: next) != nil || firstMatch(setextDashes, in: next) != nil {
                    let level = firstMatch(setextEquals, in: next) != nil ? 1 : 2
                    blocks.append(Block(level: level, text: plain(trimmed), html: "<h\(level)>\(inline(trimmed))</h\(level)>"))
                    i += 2; continue
                }
            }
            // paragraph
            var paragraph: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if !paragraph.isEmpty, startsNewBlock(l) { break }
                paragraph.append(l)
                i += 1
            }
            var html = ""
            for (n, l) in paragraph.enumerated() {
                let hardBreak = l.hasSuffix("  ") || l.hasSuffix("\\")
                var piece = l.trimmingCharacters(in: .whitespaces)
                if piece.hasSuffix("\\") { piece.removeLast() }
                html += inline(piece)
                if n < paragraph.count - 1 { html += hardBreak ? "<br/>\n" : " " }
            }
            blocks.append(Block(html: "<p>\(html)</p>"))
        }
        return blocks
    }

    /// Markdown stripped to the text a reader would see — for headings and the contents list.
    private static func plain(_ s: String) -> String {
        var t = s
        t = replacing(rx(#"!?\[([^\]]*)\]\([^)]*\)"#), in: t, with: "$1")
        t = replacing(rx(#"[*_`~]+"#), in: t, with: "")
        return collapseSpaces(t)
    }

    /// Inline Markdown → XHTML: code, links, emphasis. Everything is escaped first,
    /// so nothing the author typed can become a stray tag.
    private static func inline(_ s: String) -> String {
        // protect backslash escapes and code spans behind private-use placeholders
        var protected: [String] = []
        func hold(_ html: String) -> String {
            protected.append(html)
            return "\u{E000}\(protected.count - 1)\u{E001}"
        }
        var t = s
        let escapes = rx(#"\\([\\`*_{}\[\]()#+\-.!~])"#)
        while let m = firstMatch(escapes, in: t), let r = Range(m.range, in: t), let ch = group(m, 1, in: t) {
            t.replaceSubrange(r, with: hold(esc(ch)))
        }
        let code = rx(#"`([^`]+)`"#)
        while let m = firstMatch(code, in: t), let r = Range(m.range, in: t), let body = group(m, 1, in: t) {
            t.replaceSubrange(r, with: hold("<code>" + esc(body) + "</code>"))
        }
        t = esc(t)
        t = replacing(rx(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#), in: t, with: "$1")
        t = replacing(rx(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;.*?&quot;)?\)"#), in: t, with: "<a href=\"$2\">$1</a>")
        t = replacing(rx(#"&lt;(https?://[^&\s]+?)&gt;"#), in: t, with: "<a href=\"$1\">$1</a>")
        t = replacing(rx(#"\*\*(.+?)\*\*"#), in: t, with: "<strong>$1</strong>")
        t = replacing(rx(#"__(.+?)__"#), in: t, with: "<strong>$1</strong>")
        t = replacing(rx(#"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#), in: t, with: "<em>$1</em>")
        t = replacing(rx(#"(?<![_\w])_(?!\s)(.+?)(?<!\s)_(?![_\w])"#), in: t, with: "<em>$1</em>")
        t = replacing(rx(#"~~(.+?)~~"#), in: t, with: "<del>$1</del>")
        let placeholder = rx("\u{E000}(\\d+)\u{E001}")
        while let m = firstMatch(placeholder, in: t), let r = Range(m.range, in: t),
              let index = group(m, 1, in: t).flatMap({ Int($0) }), protected.indices.contains(index) {
            t.replaceSubrange(r, with: protected[index])
        }
        return t
    }

    // MARK: - HTML

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "eacute": "é", "egrave": "è",
        "agrave": "à", "aacute": "á", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ccedil": "ç", "ntilde": "ñ", "iexcl": "¡", "iquest": "¿", "times": "×", "frac12": "½",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.firstIndex(of: ";"), tail.distance(from: tail.startIndex, to: semi) <= 10 {
                let name = String(tail[tail.index(after: tail.startIndex)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16) {
                    replacement = Unicode.Scalar(v).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()) {
                    replacement = Unicode.Scalar(v).map { String(Character($0)) }
                } else {
                    replacement = namedEntities[name]
                }
                if let replacement {
                    out += replacement
                    rest = tail[tail.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = tail.dropFirst()
        }
        out += rest
        return out
    }

    private static func htmlSections(_ raw: String) -> ([Section], Meta) {
        var meta = Meta()
        var s = normalize(raw)
        let dotAll: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
        if let m = firstMatch(rx(#"<title[^>]*>(.*?)</title>"#, dotAll), in: s), let t = group(m, 1, in: s) {
            meta.title = collapseSpaces(decodeEntities(t))
        }
        if let m = firstMatch(rx(#"<meta[^>]+name\s*=\s*["']author["'][^>]*content\s*=\s*["']([^"']*)["']"#, .caseInsensitive), in: s),
           let a = group(m, 1, in: s) {
            meta.author = collapseSpaces(decodeEntities(a))
        }
        s = replacing(rx("<!--.*?-->", dotAll), in: s, with: "")
        s = replacing(rx(#"<(script|style|head|noscript|svg|template)\b.*?</\1\s*>"#, dotAll), in: s, with: "")
        if let m = firstMatch(rx(#"<body[^>]*>(.*)</body\s*>"#, dotAll), in: s), let body = group(m, 1, in: s) {
            s = body
        }
        let xhtml = XHTMLWriter.render(s)
        // split at the h1/h2 markers the writer left
        let pieces = xhtml.components(separatedBy: XHTMLWriter.marker)
        var sections: [Section] = []
        for (n, piece) in pieces.enumerated() {
            let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var title = ""
            if n > 0, let m = firstMatch(rx(#"^<h[12]>(.*?)</h[12]>"#, dotAll), in: body), let h = group(m, 1, in: body) {
                title = collapseSpaces(decodeEntities(replacing(rx("<[^>]+>"), in: h, with: "")))
            }
            sections.append(Section(title: title.isEmpty ? (sections.isEmpty ? "Beginning" : "") : title, body: body))
        }
        if sections.count == 1 {
            // no h1/h2 to cut at: keep it whole, or part-split when very long
            let blocks = sections[0].body.components(separatedBy: "\n")
            return (chunk(blocks), meta)
        }
        return (sections, meta)
    }

    /// Rebuilds loose HTML as well-formed XHTML: only a whitelist of tags is kept,
    /// text is unescaped then re-escaped, and every tag it opens it closes.
    private struct XHTMLWriter {
        static let marker = "\u{E100}"

        private var out = ""
        private var stack: [String] = []
        private var inPre = false
        private var atBlockStart = true

        static func render(_ html: String) -> String {
            var w = XHTMLWriter()
            w.run(html)
            return w.out
        }

        private static let containers: Set<String> = ["blockquote", "ul", "ol"]
        private static let textBlocks: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre"]
        private static let inlineKeep: [String: String] = [
            "em": "em", "i": "em", "strong": "strong", "b": "strong", "code": "code", "tt": "code",
            "sup": "sup", "sub": "sub", "u": "em", "cite": "em", "mark": "strong", "s": "del", "del": "del",
        ]
        private static let separators: Set<String> = [
            "div", "section", "article", "header", "footer", "main", "nav", "aside", "table", "tr",
            "center", "figure", "figcaption", "dl", "dt", "dd", "address", "form", "body", "html", "tbody", "thead",
        ]

        private mutating func emit(_ s: String) { out += s }

        private var hasTextBlock: Bool { stack.contains { Self.textBlocks.contains($0) } }

        private mutating func pop() {
            guard let top = stack.popLast() else { return }
            if !top.hasPrefix("~") { emit("</\(top)>") }
            if top == "pre" { inPre = false }
        }

        private mutating func closeUntil(_ tag: String) {
            guard stack.contains(tag) else { return }
            while let top = stack.last {
                pop()
                if top == tag { break }
            }
            atBlockStart = true
        }

        /// Close an open paragraph (and any inline tags in it) before a block begins.
        private mutating func closeText() {
            while let top = stack.last, !Self.containers.contains(top), top != "li" { pop() }
            atBlockStart = true
        }

        private mutating func open(_ tag: String, marker: Bool = false) {
            if marker {
                // a chapter heading is always top level: unwind whatever is open so
                // cutting the output at the marker leaves both halves well formed
                while !stack.isEmpty { pop() }
                emit(Self.marker)
            } else {
                closeText()
            }
            emit("<\(tag)>")
            stack.append(tag)
            if tag == "pre" { inPre = true }
            atBlockStart = true
        }

        private mutating func ensureTextBlock() {
            if !hasTextBlock { open("p") }
        }

        private mutating func text(_ raw: String) {
            let decoded = TextBook.decodeEntities(raw)
            if inPre {
                ensureTextBlock()
                emit(TextBook.esc(decoded))
                return
            }
            var collapsed = ""
            var lastSpace = false
            for ch in decoded {
                if ch.isWhitespace {
                    if !lastSpace { collapsed.append(" ") }
                    lastSpace = true
                } else {
                    collapsed.append(ch)
                    lastSpace = false
                }
            }
            if atBlockStart { collapsed = String(collapsed.drop(while: { $0 == " " })) }
            guard !collapsed.isEmpty else { return }
            if collapsed == " " && !hasTextBlock { return }
            ensureTextBlock()
            emit(TextBook.esc(collapsed))
            atBlockStart = false
        }

        private static let tagPattern = TextBook.rx(#"^<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*?)(/?)>$"#, .dotMatchesLineSeparators)
        private static let hrefPattern = TextBook.rx(#"href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, .caseInsensitive)

        private mutating func run(_ html: String) {
            var rest = html[...]
            while let lt = rest.firstIndex(of: "<") {
                text(String(rest[..<lt]))
                guard let gt = rest[lt...].firstIndex(of: ">") else {
                    rest = rest[rest.endIndex...]
                    break
                }
                let tag = String(rest[lt...gt])
                rest = rest[rest.index(after: gt)...]
                handle(tag)
            }
            text(String(rest))
            while !stack.isEmpty { pop() }
        }

        private mutating func handle(_ raw: String) {
            guard let m = TextBook.firstMatch(Self.tagPattern, in: raw),
                  let closing = TextBook.group(m, 1, in: raw),
                  let name = TextBook.group(m, 2, in: raw)?.lowercased() else { return }
            let attributes = TextBook.group(m, 3, in: raw) ?? ""
            let isClose = closing == "/"

            switch name {
            case "br":
                if hasTextBlock && !isClose { emit("<br/>"); atBlockStart = true } else { closeText() }
            case "hr":
                if !isClose { closeText(); emit("<hr/>") }
            case "p":
                if isClose { closeUntil("p") } else { open("p") }
            case "h1", "h2":
                if isClose { closeUntil(name) } else { open(name, marker: true) }
            case "h3", "h4", "h5", "h6":
                if isClose { closeUntil(name) } else { open(name) }
            case "blockquote":
                if isClose { closeUntil("blockquote") } else { open("blockquote") }
            case "ul", "ol":
                if isClose { closeUntil(name) } else { open(name) }
            case "li":
                if isClose {
                    closeUntil("li")
                } else {
                    // a list item belongs to a list: open one if the source forgot
                    if !stack.contains("ul") && !stack.contains("ol") { open("ul") }
                    closeUntilList()
                    emit("<li>")
                    stack.append("li")
                    atBlockStart = true
                }
            case "pre":
                if isClose { closeUntil("pre") } else { open("pre") }
            case "td", "th":
                if !isClose && hasTextBlock { emit(" ") }
            case "a":
                if isClose {
                    closeUntil("a"); closeUntil("~a")
                } else if let href = Self.externalHref(attributes) {
                    ensureTextBlock()
                    emit("<a href=\"\(TextBook.esc(href))\">")
                    stack.append("a")
                } else {
                    stack.append("~a")
                }
            case "img":
                break
            default:
                if let mapped = Self.inlineKeep[name] {
                    if isClose {
                        closeUntil(mapped)
                    } else {
                        ensureTextBlock()
                        emit("<\(mapped)>")
                        stack.append(mapped)
                    }
                } else if Self.separators.contains(name) {
                    closeText()
                }
            }
        }

        /// Close inline tags and any finished item so a new `<li>` sits directly in its list.
        private mutating func closeUntilList() {
            while let top = stack.last, top != "ul", top != "ol" { pop() }
        }

        private static func externalHref(_ attributes: String) -> String? {
            guard let m = TextBook.firstMatch(hrefPattern, in: attributes) else { return nil }
            let value = TextBook.group(m, 1, in: attributes) ?? TextBook.group(m, 2, in: attributes) ?? ""
            let decoded = TextBook.decodeEntities(value)
            let lower = decoded.lowercased()
            return (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")) ? decoded : nil
        }
    }

    // MARK: - EPUB

    private static func chapterFile(_ index: Int) -> String {
        "ch" + String(format: "%03d", index + 1) + ".xhtml"
    }

    private static func xhtml(title: String, language: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(esc(language))" lang="\(esc(language))">
        <head>
        <meta charset="utf-8"/>
        <title>\(esc(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    static func buildEPUB(
        title: String, author: String, language: String, sections: [Section], now: Date,
        cover: Cover? = nil, summary: String = ""
    ) -> Data {
        var zip = ZipWriter()
        // the mimetype entry comes first and is stored — the one rule of the container
        zip.add("mimetype", text: "application/epub+zip")
        zip.add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = formatter.string(from: now)
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
        """
        var spine = ""
        var tocItems = ""
        var coverMeta = ""
        if let cover {
            let file = "cover.\(cover.fileExtension)"
            manifest += "\n    <item id=\"cover\" href=\"\(file)\" media-type=\"\(esc(cover.mediaType))\" properties=\"cover-image\"/>"
            // the EPUB 2 way too, which some readers still look for
            coverMeta = "\n    <meta name=\"cover\" content=\"cover\"/>"
            zip.add("OEBPS/\(file)", cover.data)
        }
        for (i, section) in sections.enumerated() {
            let file = chapterFile(i)
            manifest += "\n    <item id=\"c\(i + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>"
            spine += "\n    <itemref idref=\"c\(i + 1)\"/>"
            tocItems += "\n      <li><a href=\"\(file)\">\(esc(section.title))</a></li>"
            zip.add("OEBPS/\(file)", text: xhtml(title: section.title, language: language, body: section.body))
        }
        let creator = author.isEmpty ? "" : "\n    <dc:creator>\(esc(author))</dc:creator>"
        let blurb = summary.isEmpty ? "" : "\n    <dc:description>\(esc(summary))</dc:description>"
        zip.add("OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(esc(language))">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(esc(title))</dc:title>\(creator)\(blurb)
            <dc:language>\(esc(language))</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>\(coverMeta)
          </metadata>
          <manifest>
        \(manifest)
          </manifest>
          <spine>\(spine)
          </spine>
        </package>
        """)
        zip.add("OEBPS/nav.xhtml", text: xhtml(title: "Contents", language: language, body: """
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>\(tocItems)
          </ol>
        </nav>
        """))
        zip.add("OEBPS/style.css", text: """
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.6em; text-align: start; hyphens: none; }
        p { margin: 0 0 0.9em; }
        p.verse { margin-left: 1em; }
        pre { white-space: pre-wrap; }
        blockquote { margin: 1em 1.5em; }
        """)
        return zip.finish()
    }
}
