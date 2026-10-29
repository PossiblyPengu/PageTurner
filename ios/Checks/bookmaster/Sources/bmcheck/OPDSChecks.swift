import Foundation

// The OPDS catalogue reader: a Calibre-style feed and a Gutenberg-style one, parsed offline.

private let calibre = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
  <title>Calibre Library</title>
  <link rel="search" type="application/opensearchdescription+xml" href="/opds/opensearch.xml"/>
  <link rel="next" type="application/atom+xml" href="/opds/navcatalog/4f?offset=25"/>
  <entry>
    <title>Authors</title>
    <id>urn:calibre:authors</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/opds/category/authors"/>
  </entry>
  <entry>
    <title>The Left Hand of Darkness</title>
    <id>urn:uuid:1111</id>
    <author><name>Ursula K. Le Guin</name></author>
    <content type="xhtml"><div>A &lt;b&gt;winter&lt;/b&gt; planet.</div></content>
    <link rel="http://opds-spec.org/image/thumbnail" type="image/jpeg" href="/get/thumb/12"/>
    <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/get/PDF/12/lib.pdf"/>
    <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/get/EPUB/12/lib.epub"/>
    <link rel="http://opds-spec.org/acquisition" type="application/x-mobipocket-ebook" href="/get/MOBI/12/lib.mobi"/>
  </entry>
</feed>
""".data(using: .utf8)!

private let gutenberg = """
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Search</title>
  <link rel="search" type="application/atom+xml" href="https://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}"/>
  <entry>
    <title>Emma</title><id>urn:gutenberg:158</id>
    <author><name>Austen, Jane</name></author>
    <author><name>Other, Person</name></author>
    <link rel="http://opds-spec.org/acquisition/buy" type="application/epub+zip" href="/buy"/>
    <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="//www.gutenberg.org/ebooks/158.epub.noimages"/>
  </entry>
</feed>
""".data(using: .utf8)!

func runOPDSChecks() {
    section("OPDS catalogues")
    let base = URL(string: "http://192.168.1.5:8080/opds")!
    guard let feed = OPDS.parse(calibre, base: base) else { check("a Calibre feed parses", false); return }
    check("the feed has its title and both entries", feed.title == "Calibre Library" && feed.entries.count == 2)
    check("a subsection entry is a listing to open, resolved against the server",
          feed.entries[0].navigation?.absoluteString == "http://192.168.1.5:8080/opds/category/authors" && feed.entries[0].downloads.isEmpty)
    let book = feed.entries[1]
    check("a book carries its title, author and a plain summary",
          book.title == "The Left Hand of Darkness" && book.author == "Ursula K. Le Guin" && book.summary == "A winter planet.", book.summary)
    check("the epub is offered before the pdf, and the mobi not at all",
          book.downloads.map(\.fileExtension) == ["epub", "pdf"], "\(book.downloads.map(\.fileExtension))")
    check("the thumbnail is the cover", book.cover?.absoluteString == "http://192.168.1.5:8080/get/thumb/12")
    check("a next page and a search description are noted",
          feed.next?.absoluteString == "http://192.168.1.5:8080/opds/navcatalog/4f?offset=25"
          && feed.searchDescription?.absoluteString == "http://192.168.1.5:8080/opds/opensearch.xml")

    let description = """
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Url type="text/html" template="http://x/html?q={searchTerms}"/>
      <Url type="application/atom+xml" template="/opds/search/{searchTerms}"/>
    </OpenSearchDescription>
    """.data(using: .utf8)!
    check("the search template comes out of an OpenSearch description", OPDS.searchTemplate(fromDescription: description) == "/opds/search/{searchTerms}")
    check("search terms are encoded into the address",
          OPDS.searchURL(template: "/opds/search/{searchTerms}", terms: "le guin & co", base: base)?.absoluteString
              == "http://192.168.1.5:8080/opds/search/le%20guin%20%26%20co")

    guard let g = OPDS.parse(gutenberg, base: URL(string: "https://m.gutenberg.org/ebooks.opds/")!) else { check("a Gutenberg feed parses", false); return }
    check("an inline search template is kept", g.searchTemplate == "https://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}", g.searchTemplate ?? "nil")
    check("two authors are joined, a buy link is skipped, a protocol-relative link resolves",
          g.entries[0].author == "Austen, Jane & Other, Person" && g.entries[0].downloads.count == 1
          && g.entries[0].downloads[0].url.absoluteString == "https://www.gutenberg.org/ebooks/158.epub.noimages",
          "\(g.entries[0].downloads.map(\.url))")
    check("something that is not a feed is refused", OPDS.parse(Data("<html><body>hi</body></html>".utf8), base: base) == nil)
    check("garbage is refused", OPDS.parse(Data("not xml".utf8), base: base) == nil)

    let prefixed = """
    <atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
      <atom:title>Prefixed</atom:title>
      <atom:entry>
        <atom:title>Emma</atom:title>
        <atom:link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/emma.epub"/>
      </atom:entry>
    </atom:feed>
    """.data(using: .utf8)!
    guard let p = OPDS.parse(prefixed, base: base) else { check("a feed with the atom: prefix parses", false); return }
    check("a feed with the atom: prefix parses",
          p.entries.count == 1 && p.entries[0].title == "Emma" && p.entries[0].downloads.count == 1
          && p.entries[0].downloads[0].fileExtension == "epub",
          "\(p.entries)")

    section("OPDS 2 (JSON) catalogues")
    let opds2 = """
    {
      "metadata": {"title": "Standard Ebooks"},
      "links": [
        {"rel": "next", "href": "/feeds/opds/all?page=2"},
        {"rel": "search", "href": "https://standardebooks.org/feeds/opds/all?query={searchTerms}", "templated": true}
      ],
      "navigation": [{"title": "New Releases", "href": "/feeds/opds/new-releases"}],
      "facets": [{"metadata": {"title": "Author"}, "links": [{"title": "By Author", "href": "/feeds/opds/authors"}]}],
      "groups": [{"metadata": {"title": "Subjects"}, "publications": [{
        "metadata": {"title": "The Time Machine", "identifier": "urn:uuid:tm-1",
                     "author": [{"name": "H. G. Wells"}, {"name": "Second Author"}],
                     "description": "A traveller."},
        "links": [
          {"rel": "self", "href": "/feeds/opds/publications/tm"},
          {"rel": "http://opds-spec.org/acquisition", "href": "/ebooks/tm.mobi", "type": "application/x-mobipocket-ebook"},
          {"rel": ["http://opds-spec.org/acquisition", "urn:other"], "href": "/ebooks/tm.epub", "type": "application/epub+zip"}
        ],
        "images": [
          {"href": "/covers/tm.jpg", "type": "image/jpeg", "height": 600},
          {"href": "/covers/tm-small.jpg", "type": "image/jpeg", "height": 48}
        ]
      }]}]
    }
    """.data(using: .utf8)!
    guard let j = OPDS.parse(opds2, base: URL(string: "https://standardebooks.org/feeds/opds/all")!) else {
        check("an OPDS 2 feed parses", false); return
    }
    check("the JSON feed has its title", j.title == "Standard Ebooks")
    check("next page and search template resolve",
          j.next?.absoluteString == "https://standardebooks.org/feeds/opds/all?page=2"
          && j.searchTemplate == "https://standardebooks.org/feeds/opds/all?query={searchTerms}",
          "\(j.searchTemplate ?? "nil")")
    check("navigation and facet links become listings",
          j.entries.count >= 2
          && j.entries[0].navigation?.absoluteString == "https://standardebooks.org/feeds/opds/new-releases"
          && j.entries[1].navigation?.absoluteString == "https://standardebooks.org/feeds/opds/authors",
          "\(j.entries.map { $0.navigation?.absoluteString ?? $0.title })")
    let tm = j.entries.last!
    check("a publication carries title, joined authors and description",
          tm.title == "The Time Machine" && tm.author == "H. G. Wells & Second Author" && tm.summary == "A traveller.",
          "\(tm.title) / \(tm.author) / \(tm.summary)")
    check("a rel given as a list still counts; an unopenable format is dropped",
          tm.downloads.map(\.fileExtension) == ["epub"], "\(tm.downloads)")
    check("the cover is the smallest image worth showing", tm.cover?.absoluteString == "https://standardebooks.org/covers/tm.jpg")
    check("an empty OPDS 2 feed still parses", OPDS.parse(Data("{\"metadata\":{\"title\":\"E\"}}".utf8), base: base)?.title == "E")
    check("a JSON object that is not a feed is refused", OPDS.parse(Data("{\"a\": 1}".utf8), base: base) == nil)

    section("Read-aloud skips page numbers")
    check("a bare number or a page label is a page number",
          ["42", "- 42 -", "[ 7 ]", "Page 112", "page 3"].allSatisfy(SpeechText.isPageNumber))
    check("a sentence, a long number or a chapter number word is not",
          !["It was 42 years ago.", "Chapter 3", "12345", "XII", "42 Wallaby Way"].contains(where: SpeechText.isPageNumber))
    check("spoken() drops a lone page number and keeps real text", SpeechText.spoken(" 42 ") == "" && SpeechText.spoken("Forty-two.") == "Forty-two.")
}

/// A block of a steady tone at `amplitude`, mono.
private func tone(_ amplitude: Float, frames: Int) -> [Float] {
    (0 ..< frames).map { amplitude * sinf(Float($0) * 0.05) }
}

func runVoiceDSPChecks() {
    section("Voice boost and trim silence")
    var dsp = VoiceDSP()
    dsp.boost = true
    dsp.trim = true
    dsp.sampleRate = 44_100

    var quiet = tone(0.03, frames: 1024)
    func level(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
    let before = level(quiet)
    for _ in 0 ..< 20 {
        quiet = tone(0.03, frames: 1024)
        quiet.withUnsafeMutableBufferPointer { dsp.process([$0], frames: 1024) }
    }
    check("a quiet voice is lifted", level(quiet) > before * 1.5, "\(before) -> \(level(quiet))")

    var loud = tone(0.95, frames: 1024)
    loud.withUnsafeMutableBufferPointer { dsp.process([$0], frames: 1024) }
    check("a loud one never goes past full scale", loud.allSatisfy { abs($0) <= 1.0 })

    var hiss = tone(0.001, frames: 1024)
    var hissed = VoiceDSP()
    hissed.boost = true
    for _ in 0 ..< 20 { hiss = tone(0.001, frames: 1024); hiss.withUnsafeMutableBufferPointer { hissed.process([$0], frames: 1024) } }
    check("room tone is not boosted", level(hiss) < 0.0011, "\(level(hiss))")

    var trimming = VoiceDSP()
    trimming.trim = true
    var silent = [Float](repeating: 0, count: 4096)
    silent.withUnsafeMutableBufferPointer { trimming.process([$0], frames: 4096) }
    check("a short quiet stretch is not yet silence", !trimming.inSilence)
    for _ in 0 ..< 4 { silent.withUnsafeMutableBufferPointer { trimming.process([$0], frames: 4096) } }
    check("a quarter second of quiet is silence", trimming.inSilence)
    var voice = tone(0.2, frames: 4096)
    voice.withUnsafeMutableBufferPointer { trimming.process([$0], frames: 4096) }
    check("and speech ends it", !trimming.inSilence)

    var off = VoiceDSP()
    var untouched = tone(0.03, frames: 512)
    let copy = untouched
    untouched.withUnsafeMutableBufferPointer { off.process([$0], frames: 512) }
    check("with both off the audio is left alone", untouched == copy)

    // interleaved stereo: one run, two channels per frame
    var stereo = [Float](repeating: 0.03, count: 2048)
    var pair = VoiceDSP()
    pair.boost = true
    for _ in 0 ..< 20 {
        stereo = [Float](repeating: 0.03, count: 2048)
        stereo.withUnsafeMutableBufferPointer { pair.process([$0], frames: 1024) }
    }
    check("interleaved audio is handled", stereo[0] > 0.03 && stereo[0] == stereo[1])
}
