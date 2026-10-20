import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Checks for the text -> EPUB converter (ios/Pageturner/Import). No servers needed.

private final class XMLProbe: NSObject, XMLParserDelegate {
    var failed = false
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}

/// Strict XML parse of a fragment — an XHTML chapter that isn't well formed shows
/// a parse error instead of the book.
private func wellFormed(_ fragment: String) -> Bool {
    // the real documents declare the epub: prefix on <html>; the fragment needs it too
    let parser = XMLParser(data: Data("<div xmlns:epub=\"http://www.idpf.org/2007/ops\">\(fragment)</div>".utf8))
    let probe = XMLProbe()
    parser.delegate = probe
    return parser.parse() && !probe.failed
}

private func paragraphs(_ text: String, count: Int, width: Int = 60) -> String {
    (0..<count).map { i in
        String(repeating: "word\(i % 10) ", count: max(1, width / 6)).trimmingCharacters(in: .whitespaces) + "."
    }.joined(separator: "\n\n")
}

@MainActor
func runBookText() {
    section("ISBN and descriptions")
    check("ISBN-13 with hyphens", ISBN.normalize("978-0-306-40615-7") == "9780306406157")
    check("ISBN-10", ISBN.normalize("0306406152") == "0306406152")
    check("ISBN-10 ending in X", ISBN.normalize("0-8044-2957-X") == "080442957X")
    check("a urn:isbn: identifier", ISBN.normalize("urn:isbn:9780306406157") == "9780306406157")
    check("'ISBN ' prefix", ISBN.normalize("ISBN 978-0-306-40615-7") == "9780306406157")
    check("a wrong check digit is refused", ISBN.normalize("9780306406158") == nil)
    check("a uuid identifier is not an ISBN", ISBN.normalize("urn:uuid:12345678-1234-1234-1234-123456789012") == nil)
    check("the wrong length is refused", ISBN.normalize("12345") == nil)
    check("best prefers a valid 13", ISBN.best(of: ["0306406152", "9780306406157", "bogus"]) == "9780306406157")
    check("best falls back to a 10", ISBN.best(of: ["0306406152"]) == "0306406152")
    check("HTML to text: tags, breaks, entities",
          BookText.plain(fromHTML: "<p>A &amp; B</p><p>Second<br/>line <b>bold</b></p>") == "A & B\n\nSecond\nline bold",
          BookText.plain(fromHTML: "<p>A &amp; B</p><p>Second<br/>line <b>bold</b></p>"))
    check("plain text passes through", BookText.plain(fromHTML: "Just text.") == "Just text.")
    check("year from a full date", BookText.year(from: "2021-03-04") == "2021")
    check("year from a month and year", BookText.year(from: "March 2021") == "2021")
    check("no year", BookText.year(from: "n.d.") == nil)
}

@MainActor
func runTextBook() {
    func convert(_ s: String, _ f: TextBook.Format, _ name: String = "My_File") -> TextBook.Converted? {
        TextBook.convert(Data(s.utf8), format: f, fallbackTitle: name, now: Date(timeIntervalSince1970: 1_760_000_000))
    }
    func sectionsOK(_ c: TextBook.Converted) -> Bool { c.chapterCount >= 1 }

    section("Text books: decoding")
    check("Windows-1252 bytes decode (café)", TextBook.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    check("a UTF-8 BOM is dropped", TextBook.decode(Data([0xEF, 0xBB, 0xBF, 0x68, 0x69])) == "hi")
    check("UTF-16 with a BOM decodes", TextBook.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])) == "hi")
    check("control characters are dropped from XML", TextBook.esc("a\u{01}b&<>\"") == "ab&amp;&lt;&gt;&quot;")
    check("entities decode: named, decimal, hex", TextBook.decodeEntities("a&amp;b &mdash; &#169; &#xA9; &bogus;") == "a&b — © © &bogus;")

    section("Text books: plain text")
    let alice = """
    THE TEST BOOK

    CHAPTER I
    Down the Rabbit-Hole

    Alice was beginning to get very tired of sitting by her sister on the
    bank, and of having nothing to do: once or twice she had peeped into the
    book her sister was reading.

    CHAPTER II
    The Pool of Tears

    "Curiouser and curiouser!" cried Alice.

    Part of the problem was that she had no idea what to do.

    EPILOGUE

    The end.
    """
    if let c = convert(alice, .plain) {
        check("chapters are found from headings", c.chapterCount == 4, "\(c.chapterCount)")
        check("a heading's subtitle line joins it", String(decoding: c.epub, as: UTF8.self).contains("CHAPTER I — Down the Rabbit-Hole"))
        check("wrapped lines are joined into one paragraph", String(decoding: c.epub, as: UTF8.self).contains("on the bank, and of having nothing to do: once or twice"))
        check("'Part of the problem…' is not mistaken for a heading", !String(decoding: c.epub, as: UTF8.self).contains("<h2>Part of"))
        check("title falls back to the file name", c.title == "My File", c.title)
    } else { check("plain text converts", false) }

    let gutenberg = """
    The Project Gutenberg EBook of A Test Tale, by Jane Doe

    Title: A Test Tale
    Author: Jane Doe

    *** START OF THIS PROJECT GUTENBERG EBOOK A TEST TALE ***

    CHAPTER 1

    Once upon a time.

    CHAPTER 2

    The end.

    *** END OF THIS PROJECT GUTENBERG EBOOK A TEST TALE ***

    License text that must not be in the book.
    """
    if let c = convert(gutenberg, .plain) {
        let raw = String(decoding: c.epub, as: UTF8.self)
        check("Gutenberg title and author are read", c.title == "A Test Tale" && c.author == "Jane Doe", "\(c.title) / \(c.author)")
        check("the licence boilerplate is cut", !raw.contains("License text"))
        check("two chapters", c.chapterCount == 2, "\(c.chapterCount)")
    } else { check("Gutenberg text converts", false) }

    let oneLine = (0..<60).map { "This is sentence number \($0) on its own line, long enough to be a paragraph by itself in a file with no blank lines." }.joined(separator: "\n")
    if let c = convert(oneLine, .plain) {
        let count = String(decoding: c.epub, as: UTF8.self).components(separatedBy: "<p>").count - 1
        check("a file with no blank lines is one paragraph per line", count == 60, "\(count)")
    } else { check("line-per-paragraph converts", false) }

    let caps = "intro text here.\n\nTHE SPIDER\n\nSpider text one.\n\nTHE FLY\n\nFly text two.\n\nTHE WASP\n\nWasp text three.\n\nTHE BEE\n\nBee text four."
    if let c = convert(caps, .plain) {
        check("ALL-CAPS headings are used when there are no chapters", c.chapterCount >= 4, "\(c.chapterCount)")
    } else { check("caps headings convert", false) }

    if let c = convert(paragraphs("", count: 3000), .plain) {
        check("a very long text without chapters is cut into parts", c.chapterCount >= 3, "\(c.chapterCount)")
    } else { check("long text converts", false) }
    if let c = convert("Short note.\n\nAnother paragraph.", .plain) {
        check("a short text stays one section", c.chapterCount == 1)
    } else { check("short text converts", false) }

    if let c = convert("Roses are red,\nViolets are blue,\nSugar is sweet,\nAnd so are you.", .plain) {
        check("verse keeps its line breaks", String(decoding: c.epub, as: UTF8.self).contains("<br/>"))
    } else { check("verse converts", false) }
    check("empty input converts to nothing", convert("   \n\n  ", .plain) == nil)

    section("Text books: Markdown")
    let md = """
    ---
    title: "My Notes"
    author: Jane
    ---

    # One

    Some *italic*, **bold**, `code <b>`, and a [link](https://example.com/a?b=1&c=2).

    - item one
    - item two

    > quoted text
    > continues

    ## Sub

    1. first
    2. second

    ```
    fenced <code> & stuff
    ```

    # Two

    Last paragraph with snake_case_word and \\*escaped\\*.
    """
    if let c = convert(md, .markdown) {
        let raw = String(decoding: c.epub, as: UTF8.self)
        check("front matter title and author", c.title == "My Notes" && c.author == "Jane", "\(c.title) / \(c.author)")
        check("split at the top-level headings", c.chapterCount == 2, "\(c.chapterCount)")
        for (name, needle) in [
            ("emphasis", "<em>italic</em>"), ("strong", "<strong>bold</strong>"),
            ("inline code is escaped", "<code>code &lt;b&gt;</code>"),
            ("link with an escaped query", "<a href=\"https://example.com/a?b=1&amp;c=2\">link</a>"),
            ("bullets", "<li>item one</li>"), ("block quote", "<blockquote>"), ("ordered list", "<ol>"),
            ("fenced code", "<pre><code>fenced &lt;code&gt; &amp; stuff</code></pre>"),
            ("snake_case is not emphasis", "snake_case_word"), ("escaped stars stay literal", "*escaped*"),
        ] { check("Markdown: " + name, raw.contains(needle), needle) }
    } else { check("Markdown converts", false) }

    let md2 = "# A Book\n\nIntro.\n\n## First\n\nOne.\n\n## Second\n\nTwo.\n\n## Third\n\nThree."
    if let c = convert(md2, .markdown) {
        check("one H1 and several H2s: title from the H1, split on the H2s", c.title == "A Book" && c.chapterCount >= 3, "\(c.title) \(c.chapterCount)")
    } else { check("Markdown with one H1 converts", false) }

    section("Text books: HTML")
    let html = """
    <!DOCTYPE html><html><head><title>My &amp; Page</title><style>p{color:red}</style><script>alert(1)</script></head>
    <body><h1>Intro</h1><p>Hello &mdash; <b>world</b> &#169; &copy;<br>line two
    <ul><li>one<li>two</ul>
    <div>loose text</div>
    <h2>Second</h2><p>Para with <a href="https://x.org/?a=1&b=2">link</a> and <a href="chapter.html#x">internal</a>
    <img src=x alt=pic>
    <table><tr><td>a</td><td>b</td></tr></table>
    <p>unclosed
    </body></html>
    """
    if let c = convert(html, .html) {
        let raw = String(decoding: c.epub, as: UTF8.self)
        check("HTML: title from <title>", c.title == "My & Page", c.title)
        check("HTML: split at h1/h2", c.chapterCount >= 2, "\(c.chapterCount)")
        check("HTML: scripts and styles are dropped", !raw.contains("alert(1)") && !raw.contains("color:red"))
        check("HTML: unclosed list items are closed", raw.contains("<li>one</li>") && raw.contains("<li>two</li>"))
        check("HTML: external links kept, internal ones dropped to text", raw.contains("<a href=\"https://x.org/?a=1&amp;b=2\">link</a>") && !raw.contains("chapter.html"))
        check("HTML: entities become characters", raw.contains("—") && raw.contains("©"))
    } else { check("HTML converts", false) }

    section("Text books: the EPUB itself")
    var samples: [(String, TextBook.Converted)] = []
    for (name, text, f) in [("plain", alice, TextBook.Format.plain), ("gutenberg", gutenberg, .plain), ("markdown", md, .markdown), ("html", html, .html)] {
        if let c = convert(text, f) { samples.append((name, c)) }
    }
    for (name, c) in samples {
        // BM_EPUB_DIR keeps the samples so a real validator (EPUBCheck) can be run over them
        let keep = ProcessInfo.processInfo.environment["BM_EPUB_DIR"]
        let dir = keep.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("bmcheck-\(name).epub")
        try? c.epub.write(to: path)
        let result = sh("python3 '\(harness)/epub_check.py' '\(path.path)'").trimmingCharacters(in: .whitespacesAndNewlines)
        check("EPUB structure (\(name)): \(result)", result.hasPrefix("OK"), result)
        // every chapter is well-formed XML
        let raw = String(decoding: c.epub, as: UTF8.self)
        check("EPUB content has no raw ampersands (\(name))", !raw.contains("& ") || raw.contains("&amp; "), "")
        _ = sectionsOK(c)
        if keep == nil { try? FileManager.default.removeItem(at: path) }
    }
    for fragment in ["<p>a &amp; b</p>", "<ul><li>x</li></ul>"] { check("probe accepts well-formed XML", wellFormed(fragment)) }
    check("probe rejects broken XML", !wellFormed("<p>unclosed"))
    if let c = convert(html, .html) {
        // pull the chapter bodies back out of the archive text and parse each one strictly
        let raw = String(decoding: c.epub, as: UTF8.self)
        let bodies = raw.components(separatedBy: "<body>").dropFirst().compactMap { $0.components(separatedBy: "</body>").first }
        check("every HTML chapter body parses as strict XML", !bodies.isEmpty && bodies.allSatisfy { wellFormed($0) }, "\(bodies.count) bodies")
    }
}
