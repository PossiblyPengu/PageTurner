import Foundation

/// A PDF's lines laid out again as a flowing book (PDFText.swift): running heads and page numbers go, printed lines
/// join into paragraphs (hyphenated words made whole, across a page break too), and larger lines become headings.
@MainActor
func runPDFTextChecks() {
    section("PDF text versions")
    var lines: [PDFText.Line] = []
    func add(_ text: String, page: Int, y: Double, x: Double = 72, width: Double = 450, size: Double = 11) {
        lines.append(PDFText.Line(text: text, page: page, x: x, y: y, width: width, height: size * 1.2, size: size))
    }
    for page in 0 ..< 5 {
        add("THE TEST BOOK", page: page, y: 20, x: 250, width: 100, size: 9)
        if page == 0 {
            add("Chapter One", page: page, y: 60, x: 200, width: 150, size: 18)
            add("It was the begin-", page: page, y: 100, x: 90, width: 430)
            add("ning of it all, and the rain had not stopped for days on", page: page, y: 114)
            add("end. Nobody minded.", page: page, y: 128, width: 150)
            add("A second paragraph starts with an indent and runs on", page: page, y: 142, x: 90, width: 430)
            add("to the very bottom of the page where it does not end", page: page, y: 156)
        } else if page == 1 {
            add("but carries on over the page break and only then stops.", page: page, y: 60, width: 400)
            add("A gap before this one makes it a paragraph of its own and", page: page, y: 100)
            add("it ends here.", page: page, y: 114, width: 90)
        } else if page == 2 {
            add("Chapter Two", page: page, y: 60, x: 200, width: 150, size: 18)
            add("T", page: page, y: 100, x: 72, width: 20, size: 30)
            add("he second chapter opens with a drop cap and goes on for a", page: page, y: 100, x: 100)
            add("while longer than one line.", page: page, y: 114, width: 200)
        } else {
            add("Filler text on page \(page + 1) so the running head repeats across pages.", page: page, y: 60, width: 420)
        }
        add("\(page + 1)", page: page, y: 780, x: 290, width: 10, size: 9)
    }
    guard let html = PDFText.html(lines: lines, title: "The Test Book", author: "A. Writer") else {
        check("a PDF with text lays out", false)
        return
    }
    let body = html.components(separatedBy: "<body>").last ?? html
    check("PDF: the running head is gone", !body.contains("THE TEST BOOK"), body)
    check("PDF: page numbers are gone", !body.contains("<p>1</p>") && !body.contains("<p>3</p>") && !body.contains(" 2</p>"))
    check("PDF: a larger line is a heading", body.contains("<h1>Chapter One</h1>") && body.contains("<h1>Chapter Two</h1>"), body)
    check("PDF: a hyphenated word is made whole", body.contains("It was the beginning of it all"), body)
    check("PDF: a short line on a full stop ends the paragraph", body.contains("Nobody minded.</p>"), body)
    check("PDF: an indent starts a paragraph", body.contains("<p>A second paragraph starts"), body)
    check("PDF: a paragraph carries over a page break",
          body.contains("where it does not end but carries on over the page break and only then stops.</p>"), body)
    check("PDF: a wider gap starts a paragraph", body.contains("<p>A gap before this one"), body)
    check("PDF: a drop cap joins its word", body.contains("The second chapter opens"), body)
    check("PDF: the title and author go in the head", html.contains("<title>The Test Book</title>") && html.contains("content=\"A. Writer\""))
    if let book = TextBook.convert(Data(html.utf8), format: .html, fallbackTitle: "x") {
        check("PDF: the text version is a book of chapters", book.chapterCount >= 2 && book.title == "The Test Book", "\(book.chapterCount) \(book.title)")
    } else {
        check("PDF: the text version converts", false)
    }
    check("PDF: no text is no book (a scan)", PDFText.html(lines: [], title: "x", author: "") == nil)
    check("PDF: hyphen join keeps a real dash", PDFText.joined("well-", "Known") == "well- Known" && PDFText.joined("self-", "aware") == "selfaware")
}
