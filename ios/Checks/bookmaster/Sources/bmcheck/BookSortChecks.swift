import Foundation

private func sortBook(_ title: String, author: String = "", series: String? = nil,
                      seriesIndex: Double? = nil, progression: Double? = nil,
                      bmRating: Int? = nil, addedAt: Date = Date(),
                      lastOpenedAt: Date? = nil) -> Book {
    var b = Book(id: UUID(), title: title, author: author, fileName: "\(title).epub",
                 fileNames: ["\(title).epub"], addedAt: addedAt)
    b.series = series
    b.seriesIndex = seriesIndex
    b.progression = progression
    b.bmRating = bmRating
    b.lastOpenedAt = lastOpenedAt
    return b
}

func runBookSortChecks() {
    section("Library search")

    let books = [
        sortBook("Dune", author: "Frank Herbert", series: "Dune", seriesIndex: 1),
        sortBook("Dune Messiah", author: "Frank Herbert", series: "Dune", seriesIndex: 2),
        sortBook("The Name of the Wind", author: "Patrick Rothfuss", series: "The Kingkiller Chronicle"),
        sortBook("Kitchen Confidential", author: "Anthony Bourdain"),
    ]

    check("a title word finds the book",
          BookSort.filtered(books, query: "dune").count == 2)
    check("every word must hit somewhere",
          BookSort.filtered(books, query: "dune herbert").count == 2)
    check("a word only in the series name finds the books",
          BookSort.filtered(books, query: "kingkiller").count == 1)
    check("a word that hits nothing leaves the list empty",
          BookSort.filtered(books, query: "tolkien").isEmpty)
    check("an empty query leaves the list alone",
          BookSort.filtered(books, query: "  ").count == books.count)
    check("accents and case are ignored",
          BookSort.filtered(books, query: "CONFIDENTIAL").count == 1)

    section("Library sort")

    let reading = sortBook("Slow", progression: 0.1,
                           lastOpenedAt: Date(timeIntervalSince1970: 100))
    let deep = sortBook("Deep", progression: 0.9,
                        lastOpenedAt: Date(timeIntervalSince1970: 50))
    // added longest ago, never opened — last under "recent" despite the new file
    let fresh = sortBook("Fresh", addedAt: Date(timeIntervalSince1970: 10))
    let pile = [fresh, reading, deep]

    check("progress sort puts the furthest along first",
          BookSort.sorted(pile, order: .progress).first?.title == "Deep")
    check("progress sort puts the unread book last",
          BookSort.sorted(pile, order: .progress).last?.title == "Fresh")
    check("recent sort ranks by when each was last opened",
          BookSort.sorted(pile, order: .recent).map(\.title) == ["Slow", "Deep", "Fresh"])

    let five = sortBook("Five Stars", bmRating: 5)
    let one = sortBook("One Star", bmRating: 1)
    let unrated = sortBook("Unrated")
    let shelf = [unrated, one, five]
    check("rating sort puts the best first",
          BookSort.sorted(shelf, order: .rating).first?.title == "Five Stars")
    check("rating sort puts unrated last",
          BookSort.sorted(shelf, order: .rating).last?.title == "Unrated")

    let dune2 = books[1], dune1 = books[0], kkc = books[2], kitchen = books[3]
    let bySeries = BookSort.sorted([kitchen, dune2, kkc, dune1], order: .series)
    check("series sort keeps a series in reading order",
          bySeries[0].title == "Dune" && bySeries[1].title == "Dune Messiah")
    check("series sort files series before stray books",
          bySeries.last?.title == "Kitchen Confidential")
}
