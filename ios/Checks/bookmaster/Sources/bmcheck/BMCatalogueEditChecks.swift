import Foundation

/// A book's details edited in Pageturner, carried on to BookMaster's catalogue row (`BMCatalogueEdit`): what counts as
/// a change, what the write is made of, and how two parked edits become one.
func runCatalogueEditChecks() {
    section("Edits carried on to BookMaster")
    func book(_ title: String, _ author: String, pages: Int? = nil, year: String? = nil, isbn: String? = nil) -> Book {
        var b = Book(id: UUID(), title: title, author: author, fileName: "x.epub", fileNames: ["x.epub"], addedAt: Date())
        b.pages = pages
        b.year = year
        b.isbn = isbn
        return b
    }
    let before = book("Dune", "Herbert, Frank", pages: 412, year: "1965", isbn: "9780441172719")

    check("nothing changed, nothing sent", BMCatalogueEdit.changes(from: before, to: before).isEmpty)
    var retitled = before
    retitled.title = "  Dune Messiah "
    let one = BMCatalogueEdit.changes(from: before, to: retitled)
    check("a new title is sent, trimmed, and only that", one.count == 1 && one["title"] as? String == "Dune Messiah", "\(one)")

    var reordered = before
    reordered.author = "Frank Herbert"
    check("the same author in another order is not a change", BMCatalogueEdit.changes(from: before, to: reordered).isEmpty)
    var reauthored = before
    reauthored.author = "Brian Herbert & Kevin J. Anderson"
    check("a new author goes in display order",
          BMCatalogueEdit.changes(from: before, to: reauthored)["author"] as? String == sendableAuthor("Brian Herbert & Kevin J. Anderson"),
          "\(BMCatalogueEdit.changes(from: before, to: reauthored))")
    var unauthored = before
    unauthored.author = "  "
    check("an author cannot be cleared there, so it is not sent", BMCatalogueEdit.changes(from: before, to: unauthored)["author"] == nil)
    var untitled = before
    untitled.title = " "
    check("nor a title", BMCatalogueEdit.changes(from: before, to: untitled)["title"] == nil)

    var facts = before
    facts.pages = 500
    facts.year = "1969"
    facts.isbn = "9780441013593"
    let f = BMCatalogueEdit.changes(from: before, to: facts)
    check("pages, year and ISBN go as the bridge names them",
          f["total_pages"] as? Int == 500 && f["published_year"] as? Int == 1969 && f["isbn"] as? String == "9780441013593", "\(f)")
    var cleared = before
    cleared.pages = nil
    cleared.year = nil
    cleared.isbn = nil
    let c = BMCatalogueEdit.changes(from: before, to: cleared)
    check("clearing them clears them there too", c["total_pages"] is NSNull && c["published_year"] is NSNull && c["isbn"] is NSNull, "\(c)")
    var fuzzy = before
    fuzzy.year = "c. 1965"
    check("a year that is not a number cannot be sent", BMCatalogueEdit.changes(from: before, to: fuzzy)["published_year"] == nil)

    // the write: the change laid over the row as BookMaster has it
    let row: [String: Any] = [
        "id": "b1", "title": "Dune (BookMaster's own)", "author": "Frank Herbert", "total_pages": 412, "published_year": 1965,
        "isbn": "9780441172719", "genres": "[\"Science Fiction\",\"Classics\"]",
        "cover_url": "https://covers.openlibrary.org/b/id/1-L.jpg",
    ]
    let w = BMCatalogueEdit.merged(["total_pages": 500], onto: row)
    check("a field the reader did not touch keeps BookMaster's value", w?["title"] as? String == "Dune (BookMaster's own)"
          && w?["author"] as? String == "Frank Herbert" && w?["published_year"] as? Int == 1965 && w?["isbn"] as? String == "9780441172719", "\(String(describing: w))")
    check("the change is laid over it", w?["total_pages"] as? Int == 500 && w?["book_id"] as? String == "b1")
    check("its genres are sent back, or the write would clear them", w?["genres"] as? [String] == ["Science Fiction", "Classics"], "\(String(describing: w?["genres"]))")
    check("…and its cover link", w?["cover_url"] as? String == "https://covers.openlibrary.org/b/id/1-L.jpg")
    let cleared2 = BMCatalogueEdit.merged(["isbn": NSNull(), "published_year": NSNull()], onto: row)
    check("a cleared fact is cleared in the write", cleared2?["isbn"] is NSNull && cleared2?["published_year"] is NSNull)
    check("genres read as a list too", BMCatalogueEdit.genres(["A", " B ", 3, ""]) == ["A", "B"])
    check("a link of plain http is upgraded; one that is neither is not sent",
          BMCatalogueEdit.coverLink("http://books.google.com/x.jpg") as? String == "https://books.google.com/x.jpg"
          && BMCatalogueEdit.coverLink("/api/covers/b1") is NSNull && BMCatalogueEdit.coverLink(NSNull()) is NSNull)
    check("a row with no author cannot be written", BMCatalogueEdit.merged([:], onto: ["id": "b1", "title": "X"]) == nil)
    check("…nor one that names no book", BMCatalogueEdit.merged(["title": "X", "author": "Y"], onto: [:]) == nil)

    // two edits parked while offline are one
    func body(_ pin: String, _ set: [String: Any], user: String = "pengu") -> Data {
        try! JSONSerialization.data(withJSONObject: ["username": user, "user_book_id": pin, "set": set])
    }
    check("edits to one row are the same row", BMCatalogueEdit.sameRow(body("ub1", ["title": "A"]), body("ub1", ["total_pages": 3])))
    check("edits to another row, or another reader's, are not",
          !BMCatalogueEdit.sameRow(body("ub1", [:]), body("ub2", [:])) && !BMCatalogueEdit.sameRow(body("ub1", [:]), body("ub1", [:], user: "kristenkrae")))
    let merged = BMCatalogueEdit.merging(older: body("ub1", ["title": "A", "total_pages": 300]),
                                        newer: body("ub1", ["title": "B", "isbn": "9780441172719"]))
    let set = ((try? JSONSerialization.jsonObject(with: merged)) as? [String: Any])?["set"] as? [String: Any]
    check("parked edits become one, the later change winning field by field",
          set?["title"] as? String == "B" && set?["total_pages"] as? Int == 300 && set?["isbn"] as? String == "9780441172719", "\(String(describing: set))")
}
