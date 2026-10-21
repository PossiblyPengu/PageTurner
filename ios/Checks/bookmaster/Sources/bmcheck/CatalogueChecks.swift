import Foundation

/// The catalogue matching and ranking ports — BookMatching.swift and
/// BookRanking.swift run the cases BookMaster's own tests set for
/// shared/matching.ts and shared/ranking.ts, so a hit lands in the same
/// place whichever app asked.
private func hit(_ title: String, _ author: String, cover: String? = nil,
                 pages: Int? = nil, year: Int? = nil) -> CatalogueHit {
    CatalogueHit(key: "ol:\(title)", source: "test", openLibraryId: "ol",
                 title: title, author: author, coverUrl: cover, summary: nil,
                 genres: [], publishedYear: year, isbn: nil, totalPages: pages)
}

@MainActor
func runCatalogueChecks() {
    section("Matching (shared/matching.ts ported)")
    check("fold strips accents, brackets and case",
          BookMatch.fold("Alas de Ónix (Onyx Storm)") == "alas de onix")
    check("fold drops the apostrophe", BookMatch.fold("Ender's Game") == "enders game")
    check("same book", BookMatch.titlesMatch("Dune", "Dune"))
    check("a series note Goodreads appends folds away",
          BookMatch.titlesMatch("Ender's Game (Ender's Saga, #1)", "Enders Game"))
    check("edition subtitle still the same book",
          BookMatch.titlesMatch("The Fellowship of the Ring", "The Fellowship of the Ring: Part One"))
    check("a two-letter prefix is not a match", !BookMatch.titlesMatch("It", "It Ends With Us"))
    check("a different book sharing the stem is refused", !BookMatch.titlesMatch("Dune", "Dune Messiah"))
    check("a series record for the wrong volume is refused",
          !BookMatch.volumesAgree("Tales from the Gas Station: Volume Four", "Tales from the Gas Station"))
    check("a record with no number is the first volume",
          BookMatch.volumesAgree("Tales from the Gas Station: Volume One", "Tales from the Gas Station"))
    check("either side may spell the volume",
          BookMatch.volumesAgree("Cursed Fates (Zodiac Academy, #5)", "Zodiac Academy 5"))
    check("no volume named is no opinion", BookMatch.volumesAgree("Dune", "Dune"))
    check("author inside an '&' credit", BookMatch.authorsMatch("Susanne Valenti", ["Caroline Peckham & Susanne Valenti"]))
    check("a wrong co-author is refused", !BookMatch.authorsMatch("Frank Herbert", ["Caroline Peckham & Susanne Valenti"]))
    check("bareTitle drops the series note", BookMatch.bareTitle("Dune (Dune Chronicles, #1)") == "Dune")
    check("titleQueries names the series and number",
          BookMatch.titleQueries("Onyx Storm (The Empyrean, #3)").contains("The Empyrean 3"))

    section("Ranking (shared/ranking.ts ported)")
    var ranked = BookRank.rankResults(
        [hit("The Nightingale", "Kristin Hannah"),
         hit("The Women", "Kristin Hannah"),
         hit("The Great Alone", "Kristin Hannah")],
        query: "the women kristin hannah")
    check("the book the query names leads its siblings", ranked[0].title == "The Women")

    ranked = BookRank.rankResults(
        [hit("Empyrean Series, 3 Books Collection Set, Fourth Wing, Iron Flame, Onyx Storm", "Rebecca Yarros"),
         hit("Onyx Storm", "Rebecca Yarros")],
        query: "onyx storm")
    check("a box set is marked down", ranked[0].title == "Onyx Storm")
    ranked = BookRank.rankResults(
        [hit("Empyrean Series, 3 Books Collection Set, Fourth Wing, Iron Flame, Onyx Storm", "Rebecca Yarros"),
         hit("Onyx Storm", "Rebecca Yarros")],
        query: "empyrean box set")
    check("…unless a set is what was asked", ranked[0].title.contains("Collection Set"))

    ranked = BookRank.rankResults(
        [hit("Dune", "Frank Herbert", year: 1965), hit("Dune", "Brian Herbert")],
        query: "dune")
    check("a tie keeps the catalogue order", ranked.map(\.author) == ["Frank Herbert", "Brian Herbert"])

    ranked = BookRank.rankResults(
        [hit("Onyx Storm", "Rebecca Yarros"),
         hit("Onyx Storm", "Rebecca Yarros", cover: "https://covers.openlibrary.org/b/id/1-L.jpg", pages: 544)],
        query: "onyx storm")
    check("a duplicate folds, lending its cover and pages",
          ranked.count == 1 && ranked[0].coverUrl?.contains("/id/1-") == true && ranked[0].totalPages == 544)

    ranked = BookRank.rankResults(
        [hit("Summary of Educated by Tara Westover", "Book Summaries"),
         hit("Educated", "Tara Westover")],
        query: "educated tara westover")
    check("a study aid riding the title sinks", ranked[0].title == "Educated" && ranked[1].title.hasPrefix("Summary"))

    ranked = BookRank.rankResults(
        [hit("The Women", "Kristin Hannah"), hit("The women", "Unknown"), hit("The Nightingale", "Kristin Hannah")],
        query: "the women kristin hannah")
    check("an author-less stub goes last", ranked.map(\.author) == ["Kristin Hannah", "Kristin Hannah", "Unknown"])

    ranked = BookRank.rankResults([hit("B", "x"), hit("A", "y")], query: "978-0-441-01359-3")
    check("an ISBN search keeps the catalogue order", ranked.map(\.title) == ["B", "A"])

    ranked = BookRank.rankResults(
        [hit("Harry Potter and the Philosopher's Stone", "J. K. Rowling"),
         hit("Harry Potter and the Prisoner of Azkaban", "J. K. Rowling")],
        query: "harry potter prisoner of azkaban")
    check("the right volume wins without the author", ranked[0].title == "Harry Potter and the Prisoner of Azkaban")

    section("preferEdition")
    var shown = BookRank.preferEdition(
        work: (title: "Alas de ónix", coverI: 14826089),
        edition: BookRank.EditionHint(title: "Onyx Storm", coverI: 15233608, languages: ["eng"]),
        author: "Rebecca Yarros", query: "onyx storm")
    check("a translation shows the searched-for edition",
          shown.title == "Onyx Storm" && shown.coverI == 15233608)
    let work = (title: "The Women", coverI: Optional(14631595))
    shown = BookRank.preferEdition(
        work: work,
        edition: BookRank.EditionHint(title: "The Women", coverI: 14593018, languages: ["eng"]),
        author: "Kristin Hannah", query: "the women kristin hannah")
    check("a same-title English edition keeps the work's cover",
          shown.title == work.title && shown.coverI == work.coverI)
    shown = BookRank.preferEdition(
        work: (title: "Dune", coverI: 1),
        edition: BookRank.EditionHint(title: "Dune (Ace, 2005)", coverI: 2, languages: ["fre"]),
        author: "Frank Herbert", query: "978-0-441-01359-3")
    check("an ISBN search shows that edition's cover",
          shown.title == "Dune" && shown.coverI == 2)
    shown = BookRank.preferEdition(
        work: (title: "Fourth Wing", coverI: 14407898),
        edition: BookRank.EditionHint(title: "Fourth WIng", coverI: 1),
        author: "Rebecca Yarros", query: "fourth wing")
    check("an edition that answers no better stays put",
          shown.title == "Fourth Wing" && shown.coverI == 14407898)
    shown = BookRank.preferEdition(
        work: (title: "Alas de ónix", coverI: 2),
        edition: BookRank.EditionHint(title: "Onyx Storm", coverI: 3),
        author: "Rebecca Yarros", query: "alas de onix")
    check("the translation searched for is kept", shown.title == "Alas de ónix" && shown.coverI == 2)

    section("relevance")
    check("exact title + whole author name ≈ 2.8",
          abs(BookRank.relevance(title: "Piranesi", author: "Susanna Clarke", query: "piranesi susanna clarke") - 2.8) < 0.05,
          "\(BookRank.relevance(title: "Piranesi", author: "Susanna Clarke", query: "piranesi susanna clarke"))")
    check("sharing only the author scores well under",
          BookRank.relevance(title: "Jonathan Strange & Mr Norrell", author: "Susanna Clarke", query: "piranesi susanna clarke") < 1.6)
    check("a typo answers below the word itself",
          BookRank.relevance(title: "Fourth Wing", author: "Rebecca Yarros", query: "forth wing") > 1.5
              && BookRank.relevance(title: "Fourth Wing", author: "Rebecca Yarros", query: "forth wing")
                 < BookRank.relevance(title: "Fourth Wing", author: "Rebecca Yarros", query: "fourth wing"))
    check("the word still being typed counts as its start",
          BookRank.relevance(title: "Throne of Glass", author: "Sarah J. Maas", query: "throne of gla") > 1.8
              && BookRank.relevance(title: "Throne of Glass", author: "Sarah J. Maas", query: "throne of gla ") < 1.8)
    check("a short word must be exact",
          BookRank.relevance(title: "The King", author: "Someone Else", query: "wing") == 0)
    check("the author's whole name beats a coincidence",
          BookRank.relevance(title: "The Nightingale", author: "Kristin Hannah", query: "kristen hannah")
              > BookRank.relevance(title: "Charming Hannah", author: "Kristen Proby", query: "kristen hannah"))
    let pamphlet = "Andrea Palladio and the Winged Device a Panorama Painted in Prose and Pictures Setting Forth the Far-Flung Influence of Andrea Palladio Architect of Vicenza Italy on Architecture All over the World"
    check("a catalogue oddity sinks",
          BookRank.relevance(title: pamphlet, author: "James Reynolds", query: "forth wing")
              < BookRank.relevance(title: "Fourth Wing", author: "Rebecca Yarros", query: "forth wing"))

    section("correctQuery")
    let found: [(title: String, author: String)] = [
        ("Fourth Wing", "Rebecca Yarros"),
        ("Iron Flame", "Rebecca Yarros"),
        ("Summer Island", "Kristin Hannah"),
        ("Throne of Glass", "Sarah J. Maas"),
    ]
    check("a slip is spelled the catalogue's way", BookRank.correctQuery("forth wing", found: found) == "fourth wing")
    check("the author's name too", BookRank.correctQuery("kristen hannah", found: found) == "kristin hannah")
    check("the word being typed is finished", BookRank.correctQuery("throne of gla", found: found) == "throne of glass")
    check("a query that already reads right is left alone", BookRank.correctQuery("fourth wing", found: found) == nil)
    check("nothing near is nothing to say", BookRank.correctQuery("piranesi", found: found) == nil
          && BookRank.correctQuery("forth wing", found: []) == nil)

    ranked = BookRank.rankResults(
        [hit("Twenty years on the wing", "John Murray Spear"), hit("Fourth Wing", "Rebecca Yarros")],
        query: "forth wing", meant: "fourth wing")
    check("a corrected search scores by whichever query answers", ranked[0].title == "Fourth Wing")

    section("Knock-offs (what Apple returned for 'project hail mary')")
    let apple = [
        hit("Project Hail Mary", "Andy Weir"),
        hit("Project Hail Mary", "Andy Weir"),
        hit("Project Hail Mary By Andy Weir", "Easy Reads"),
        hit("After Reading Project Hail Mary by Andy Weir", "John Korsh"),
        hit("Summary of Project Hail Mary By Andy Weir", "Simple Read"),
        hit("Project Hail Mary Summary", "Instant-Summary"),
        hit("Project Hail Mary Ultimate Movie Guide", "Miles Ardent"),
        hit("Hail Mary", "Hope Anika"),
    ]
    ranked = BookRank.rankResults(apple, query: "project hail mary")
    let hail = ranked.firstIndex(where: { $0.title == "Hail Mary" }) ?? ranked.count
    check("the ebook and audiobook fold, riders fall below the honest near-miss",
          ranked.filter { $0.author == "Andy Weir" }.count == 1 && ranked[0].author == "Andy Weir"
              && ranked.dropFirst().allSatisfy { $0.title == "Hail Mary" || ranked.firstIndex(of: $0)! > hail })
    check("titles that merely contain 'by' are left alone",
          abs(BookRank.relevance(title: "Death by Chocolate", author: "Sarah Graves", query: "death by chocolate") - 2) < 0.05
              && abs(BookRank.relevance(title: "Stand By Me", author: "Stephen King", query: "stand by me") - 2) < 0.05)
    ranked = BookRank.rankResults([hit("Dune", "Frank Herbert"), hit("Dune Study Guide", "SparkNotes")],
                                  query: "dune study guide")
    check("a guide wins when a guide was asked for", ranked[0].title == "Dune Study Guide")

    section("Shelf pinning (the local ladder)")
    let row = BMShelfRow(userBookId: "ub1", bookId: "b1", title: "Dune", author: "Frank Herbert",
                         status: "reading", rating: nil, upNext: nil, percent: nil, format: nil,
                         totalPages: nil, openLibraryId: "OL9W", isbn: "9780441172719",
                         publishedYear: nil, description: nil, coverUrl: nil,
                         finishDate: nil, updatedAt: nil)
    check("an Open Library id pins",
          BMShelf.match(title: "Wrong Name", author: "Nobody", isbn: nil, openLibraryId: "OL9W", in: [row])?.userBookId == "ub1")
    check("an ISBN pins", BMShelf.match(title: "Wrong Name", author: "Nobody", isbn: "978-0-441-17271-9",
                                      openLibraryId: nil, in: [row])?.userBookId == "ub1")
    check("a folded title and author pin",
          BMShelf.match(title: "Dune: Deluxe Edition", author: "Herbert, Frank", isbn: nil,
                        openLibraryId: nil, in: [row])?.userBookId == "ub1")
    check("a stranger does not",
          BMShelf.match(title: "Dune Messiah", author: "Frank Herbert", isbn: nil, openLibraryId: nil, in: [row]) == nil)

    var books = [hit("Dune", "Frank Herbert"), hit("Hyperion", "Dan Simmons")]
    CatalogueSearch.pin(&books, to: [row])
    check("pin flags the shelved hit only",
          books[0].userBookId == "ub1" && books[0].bookId == "b1" && books[0].status == "reading"
              && books[1].userBookId == nil)

    section("Metadata dedupe (the sources line)")
    func cand(_ title: String, _ author: String, source: String, year: String = "",
              isbn: String? = nil, covers: [String] = []) -> MetadataCandidate {
        MetadataCandidate(title: title, authors: author, year: year, isbn: isbn,
                          coverURLs: covers.compactMap { URL(string: $0) }, source: source)
    }
    var merged = MetadataLookup.dedupe([
        cand("Dune", "Frank Herbert", source: "Open Library", year: "1965",
             covers: ["https://covers.openlibrary.org/b/id/1-L.jpg"]),
        cand("Dune", "Frank Herbert", source: "Google Books",
             covers: ["https://books.google.com/books/content?id=x"]),
    ])
    check("two catalogues' same book folds to one", merged.count == 1)
    check("the folded-in source is still named",
          merged.count == 1 && merged[0].source == "Open Library"
              && merged[0].contributors == ["Google Books"])
    check("its jacket joins the fallback chain",
          merged.count == 1 && merged[0].coverURLs.count == 2
              && merged[0].coverURLs[0].absoluteString.contains("openlibrary"))

    merged = MetadataLookup.dedupe([
        cand("Dune", "Frank Herbert", source: "Open Library"),
        cand("Dune", "Frank Herbert", source: "Apple Books", year: "1965"),
        cand("Dune", "Frank Herbert", source: "Google Books"),
        cand("Dune Messiah", "Frank Herbert", source: "Open Library"),
    ])
    check("a three-way fold keeps every name, a different book keeps its row",
          merged.count == 2 && merged[0].contributors == ["Apple Books", "Google Books"]
              && merged[0].year == "1965" && merged[1].contributors.isEmpty)

    var folded = cand("Dune", "Frank Herbert", source: "Apple Books")
    folded.contributors = ["Google Books"]
    merged = MetadataLookup.dedupe([cand("Dune", "Frank Herbert", source: "Open Library"), folded])
    check("a folded-in match's own contributors come along",
          merged.count == 1 && merged[0].contributors == ["Apple Books", "Google Books"])

    merged = MetadataLookup.dedupe([
        cand("Dune", "Frank Herbert", source: "Open Library", isbn: "9780441172719"),
        cand("Dune", "Frank Herbert", source: "Google Books", year: "1965"),
    ])
    check("the survivor borrows what it lacked",
          merged.count == 1 && merged[0].year == "1965" && merged[0].isbn == "9780441172719")
    check("a title-less husk is dropped",
          MetadataLookup.dedupe([cand("!!!", "", source: "Open Library")]).isEmpty)

    section("Cover links")
    check("a 978 ISBN-13 becomes its ISBN-10 for Amazon's lookup",
          CoverLinks.amazon("9780441172719")
              == [URL(string: "https://images-na.ssl-images-amazon.com/images/P/0441172717.01.LZZZZZZZ.jpg")!])
    check("an ISBN-10 is used as it stands",
          CoverLinks.amazon("0441172717")
              == [URL(string: "https://images-na.ssl-images-amazon.com/images/P/0441172717.01.LZZZZZZZ.jpg")!])
    check("a 979 ISBN-13 has no ten-digit form", CoverLinks.amazon("9791090636071").isEmpty)
    check("Audible art asks for the biggest marker first",
          CoverLinks.audibleArt("https://m.media-amazon.com/images/I/71-1WBgjGoL.jpg").first?.absoluteString
              == "https://m.media-amazon.com/images/I/71-1WBgjGoL._SL1500_.jpg")
    check("an edition's ocaid finds its archive.org scan",
          CoverLinks.archiveScan("dune0000fran")
              == [URL(string: "https://archive.org/services/img/dune0000fran")])

    var rich = hit("Dune", "Frank Herbert", cover: "https://covers.openlibrary.org/b/id/1-L.jpg")
    rich.isbn = "9780441172719"
    rich.extraCoverURLs = [URL(string: "https://covers.openlibrary.org/b/id/2-L.jpg")!]
    rich.tailCoverURLs = [URL(string: "https://archive.org/services/img/dune0000fran")]
    check("jackets run own art, sibling editions, guesses, then last resorts",
          rich.coverURLs[0].absoluteString.contains("/id/1-")
              && rich.coverURLs[1].absoluteString.contains("/id/2-")
              && rich.coverURLs.last?.absoluteString.contains("archive.org") == true
              && rich.coverURLs.contains { $0.absoluteString.contains("images-na.ssl-images-amazon.com") })
}
