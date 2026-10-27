import Foundation

/// FictionBook 2 → EPUB (FB2Book.swift through TextBook): the description's title, authors, language, blurb and
/// cover; sections as chapters; poems, notes and inline marks; and an EPUB a reader can open.
@MainActor
func runFB2Checks() {
    section("FB2 books")
    let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]).base64EncodedString()
    let fb2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
      <description>
        <title-info>
          <genre>sf</genre>
          <author><first-name>Ivan</first-name><middle-name>I.</middle-name><last-name>Petrov</last-name></author>
          <author><nickname>Anna Lee</nickname></author>
          <book-title>The Test &amp; Book</book-title>
          <annotation><p>A first line.</p><p>A second one.</p></annotation>
          <coverpage><image l:href="#cover.jpg"/></coverpage>
          <lang>ru</lang>
        </title-info>
        <document-info><author><first-name>Maker</first-name><last-name>Tool</last-name></author></document-info>
      </description>
      <body>
        <title><p>The Test Book</p></title>
        <epigraph><p>Words before.</p><text-author>Someone</text-author></epigraph>
        <section>
          <title><p>Chapter 1</p><p>The Start</p></title>
          <p>It began <emphasis>here</emphasis>, and <strong>loudly</strong>.<a l:href="#n1" type="note">1</a></p>
          <empty-line/>
          <poem><stanza><v>Line one</v><v>Line two</v></stanza></poem>
        </section>
        <section>
          <title><p>Chapter 2</p></title>
          <p>More, with a <a l:href="https://example.org/">link</a>.</p>
        </section>
      </body>
      <body name="notes">
        <title><p>Notes</p></title>
        <section id="n1"><title><p>1</p></title><p>The note itself.</p></section>
      </body>
      <binary id="cover.jpg" content-type="image/jpeg">\(cover)</binary>
    </FictionBook>
    """
    guard let c = TextBook.convert(Data(fb2.utf8), format: .fb2, fallbackTitle: "file", now: Date(timeIntervalSince1970: 1_760_000_000)) else {
        check("FB2 converts", false)
        return
    }
    let raw = String(decoding: c.epub, as: UTF8.self)
    check("FB2: the book's own title", c.title == "The Test & Book", c.title)
    check("FB2: the authors, not the file's maker", c.author == "Ivan I. Petrov, Anna Lee", c.author)
    check("FB2: the language it names", c.language == "ru", c.language)
    check("FB2: a chapter per section, and the notes", c.chapterCount >= 3, "\(c.chapterCount)")
    check("FB2: a two-line title reads as one heading", raw.contains("Chapter 1. The Start"))
    check("FB2: emphasis and strong are kept", raw.contains("<em>here</em>") && raw.contains("<strong>loudly</strong>"))
    check("FB2: a note's number is a superscript", raw.contains("<sup>1</sup>"))
    check("FB2: an outside link stays a link", raw.contains("<a href=\"https://example.org/\">link</a>"))
    check("FB2: the notes body is a chapter at the end", raw.contains("The note itself."))
    check("FB2: a poem is a quote", raw.contains("<blockquote>") && raw.contains("Line two"))
    check("FB2: the cover goes in the EPUB", raw.contains("properties=\"cover-image\"") && raw.contains("OEBPS/cover.jpg"))
    check("FB2: the blurb is the description", raw.contains("<dc:description>A first line. A second one.</dc:description>"))
    check("FB2: the description's text is not read as the book", !raw.contains("<p>A first line.</p>"))

    let path = FileManager.default.temporaryDirectory.appendingPathComponent("bmcheck-fb2.epub")
    try? c.epub.write(to: path)
    let result = sh("python3 '\(harness)/epub_check.py' '\(path.path)'").trimmingCharacters(in: .whitespacesAndNewlines)
    check("EPUB structure (fb2): \(result)", result.hasPrefix("OK"), result)
    try? FileManager.default.removeItem(at: path)

    check("FB2: not XML is no book", TextBook.convert(Data("plain words".utf8), format: .fb2, fallbackTitle: "x") == nil)
    check("FB2: the extension is known", TextBook.format(forExtension: "FB2") == .fb2)
}
