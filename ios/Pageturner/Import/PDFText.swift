import Foundation

/// A PDF's text laid out again as a book that flows: the lines PDFKit finds on each page come in, and HTML for
/// `TextBook` comes out — running heads and page numbers dropped, the hard line breaks of the printed page joined
/// back into paragraphs (a word hyphenated across lines made whole), and lines set larger than the text taken for
/// headings, which become the chapters. The PDF's own page layout can't be known from its text alone, so this
/// goes by what printed pages do: a paragraph starts after a wider gap, an indent, or a short line that ended a
/// sentence. Pure Foundation, so it is checked off-device.
enum PDFText {
    /// One printed line. `y` is its top, measured down from the top of its page; sizes in points.
    struct Line: Equatable {
        var text: String
        var page: Int
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// The font size, or the line's height when the PDF does not say.
        var size: Double
    }

    /// The whole book as HTML with a `<title>` (and author), or nil when the PDF has no text (scanned pages).
    static func html(lines raw: [Line], title: String, author: String) -> String? {
        let all = raw.map(cleaned).filter { !$0.text.isEmpty }
        let body = bodySize(all)
        let lines = dropRunningLines(all, body: body)
        guard lines.count >= 3 else { return nil }
        let gap = lineGap(lines, body: body)
        let margin = leftMargin(lines, body: body)
        let measure = lines.filter { abs($0.size - body) < 0.6 }.map(\.width).sorted()
        let fullWidth = measure.isEmpty ? 0 : measure[Int(Double(measure.count - 1) * 0.9)]

        var out = ""
        var paragraph = ""
        var heading: (level: Int, text: String)?

        func flushParagraph() {
            let text = paragraph.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out += "<p>\(TextBook.esc(text))</p>\n" }
            paragraph = ""
        }
        func flushHeading() {
            if let heading, !heading.text.isEmpty {
                out += "<h\(heading.level)>\(TextBook.esc(heading.text))</h\(heading.level)>\n"
            }
            heading = nil
        }

        for (i, line) in lines.enumerated() {
            let previous = i > 0 ? lines[i - 1] : nil
            if let level = headingLevel(line, body: body) {
                flushParagraph()
                // a heading set over two lines is one heading
                if let current = heading, current.level == level, let previous, previous.page == line.page,
                   line.y - previous.y < previous.height * 2.2 {
                    heading?.text = current.text + " " + line.text
                } else {
                    flushHeading()
                    heading = (level, line.text)
                }
                continue
            }
            flushHeading()
            // a drop cap's letter waits for the line beside it, however that line is set
            let dropCap = paragraph.count == 1 && paragraph.first?.isUppercase == true
            if let previous, !dropCap, startsParagraph(line, after: previous, gap: gap, margin: margin, fullWidth: fullWidth) {
                flushParagraph()
            }
            paragraph = joined(paragraph, line.text)
        }
        flushParagraph()
        flushHeading()
        guard !out.isEmpty else { return nil }
        let meta = author.isEmpty ? "" : "<meta name=\"author\" content=\"\(TextBook.esc(author))\"/>"
        return "<html><head><title>\(TextBook.esc(title))</title>\(meta)</head><body>\n\(out)</body></html>"
    }

    // MARK: - The parts

    private static func cleaned(_ line: Line) -> Line {
        var line = line
        line.text = line.text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return line
    }

    /// A line that turns up at the top or bottom of many pages — the book's title, a chapter's name, a page number —
    /// is the page's furniture, not the book. Only the letters are compared, so "12" and "- 13 -" match (and, having
    /// none, are page numbers). A line set larger than the text is a heading, wherever it sits.
    static func dropRunningLines(_ lines: [Line], body: Double) -> [Line] {
        let pages = Dictionary(grouping: lines, by: \.page)
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter }
        }
        var edgeCounts: [String: Int] = [:]
        var edges: Set<String> = []   // "page:index" of the first and last lines of each page
        for (page, list) in pages {
            let sorted = list.sorted { $0.y < $1.y }
            for line in [sorted.first, sorted.last].compactMap({ $0 }) {
                edgeCounts[key(line.text), default: 0] += 1
                edges.insert("\(page):\(line.y)")
            }
        }
        let threshold = max(3, pages.count / 4)
        return lines.filter { line in
            guard edges.contains("\(line.page):\(line.y)"), headingLevel(line, body: body) == nil else { return true }
            let k = key(line.text)
            // a bare page number ("12", "- 12 -", "xiv") at an edge
            if k.isEmpty || isRomanNumeral(line.text) { return false }
            return pages.count < 4 || (edgeCounts[k] ?? 0) < threshold
        }
    }

    private static func isRomanNumeral(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return !t.isEmpty && t.count <= 7 && t.allSatisfy { "ivxlc".contains($0) }
    }

    /// The size most of the text is set in, by length.
    static func bodySize(_ lines: [Line]) -> Double {
        var counts: [Double: Int] = [:]
        for line in lines { counts[(line.size * 2).rounded() / 2, default: 0] += line.text.count }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12
    }

    /// The usual distance from one line's top to the next one's, in the body text.
    private static func lineGap(_ lines: [Line], body: Double) -> Double {
        var gaps: [Double] = []
        for i in 1 ..< lines.count where lines[i].page == lines[i - 1].page {
            let d = lines[i].y - lines[i - 1].y
            if d > 0, abs(lines[i].size - body) < 0.6 { gaps.append(d) }
        }
        guard !gaps.isEmpty else { return body * 1.2 }
        return gaps.sorted()[gaps.count / 2]
    }

    /// Where the body text's lines begin (the most common start, to a point).
    private static func leftMargin(_ lines: [Line], body: Double) -> Double {
        var counts: [Double: Int] = [:]
        for line in lines where abs(line.size - body) < 0.6 { counts[line.x.rounded(), default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0
    }

    private static func headingLevel(_ line: Line, body: Double) -> Int? {
        // a drop cap is one big letter, not a heading
        guard line.text.count <= 120, body > 0, line.text.filter(\.isLetter).count >= 2 else { return nil }
        if line.size >= body * 1.6 { return 1 }
        if line.size >= body * 1.2 { return 2 }
        return nil
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\u{201D}", "\"", "'", "\u{2019}", ":", "…"]

    static func startsParagraph(_ line: Line, after previous: Line, gap: Double, margin: Double, fullWidth: Double) -> Bool {
        let endedSentence = previous.text.last.map { sentenceEnds.contains($0) } ?? false
        let shortLast = fullWidth > 0 && previous.width < fullWidth * 0.8
        if line.page != previous.page {
            // a new page carries the paragraph on, unless the last one ended short on a full stop, or this one is indented
            return (endedSentence && shortLast) || line.x > margin + line.size * 0.8
        }
        if line.y - previous.y > gap * 1.45 { return true }
        if line.x > margin + line.size * 0.8 && abs(line.x - previous.x) > 1 { return true }
        return endedSentence && shortLast
    }

    /// The text so far and the next line: a word broken at a hyphen is made whole again ("begin-" + "ning"),
    /// everything else gets a space.
    static func joined(_ text: String, _ next: String) -> String {
        guard !text.isEmpty else { return next }
        // a drop cap's letter belongs to the word the next line carries on
        if text.count == 1, text.first?.isUppercase == true, next.first?.isLowercase == true { return text + next }
        if text.hasSuffix("-"), let first = next.first, first.isLowercase,
           let before = text.dropLast().last, before.isLetter {
            return String(text.dropLast()) + next
        }
        return text + " " + next
    }
}
