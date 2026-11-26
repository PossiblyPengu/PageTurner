import Foundation

private func ending(_ title: String, _ author: String, read: Double? = nil, audio: Bool = false) -> Book {
    let file = audio ? "\(title).m4b" : "\(title).epub"
    var b = Book(id: UUID(), title: title, author: author, fileName: file, fileNames: [file], addedAt: Date())
    b.progression = read
    return b
}

/// When a book is finished (`BookEnding`): the end of the story, not the start of the last page, and not the back
/// matter after it.
func runBookEndingChecks() {
    section("Finishing a book")
    check("back matter is known by its name", BookEnding.isBackMatter("Acknowledgments") && BookEnding.isBackMatter("About the Author")
          && BookEnding.isBackMatter("ALSO BY CASSANDRA KHAW") && BookEnding.isBackMatter("A Sneak Peek at Book Two")
          && BookEnding.isBackMatter("Reading Group Guide") && BookEnding.isBackMatter("Copyright") && BookEnding.isBackMatter("Notes")
          && BookEnding.isBackMatter("End Credits") && BookEnding.isBackMatter("Copyright Page") && BookEnding.isBackMatter("Index of Names")
          && BookEnding.isBackMatter("Excerpt from Book Two") && BookEnding.isBackMatter("Credits and Permissions"))
    check("the story is not", !BookEnding.isBackMatter("Chapter 40") && !BookEnding.isBackMatter("Epilogue")
          && !BookEnding.isBackMatter("Afterword") && !BookEnding.isBackMatter("Bonus Epilogue")
          && !BookEnding.isBackMatter("Notes from the Underground Railroad") && !BookEnding.isBackMatter("The Index Card"))

    let book: [(title: String, start: Double)] = [
        ("Copyright", 0), ("Chapter 1", 0.02), ("Chapter 2", 0.4), ("Epilogue", 0.88),
        ("Acknowledgments", 0.93), ("About the Author", 0.96), ("Also by Quinn Connor", 0.98),
    ]
    check("the story ends where the back matter that closes the book begins", BookEnding.storyEnd(book) == 0.93,
          "\(BookEnding.storyEnd(book) ?? -1)")
    check("front matter of the same kind does not count", BookEnding.storyEnd(Array(book.prefix(4))) == nil)
    check("back matter of half the book is a misreading, not an ending",
          BookEnding.storyEnd([("Chapter 1", 0), ("Index", 0.3)]) == nil)
    check("in seconds too (an audiobook's closing credits)",
          BookEnding.storyEnd([("Chapter 1", 0), ("Chapter 2", 3000), ("End Credits", 7100)], end: 7200) == 7100)

    check("the last page reaches the end, though it starts short of it", BookEnding.showsEnd(visibleUpTo: 1, storyEnd: nil)
          && !BookEnding.showsEnd(visibleUpTo: 0.985, storyEnd: nil))
    check("the last page of the story is the end, with back matter after it", BookEnding.showsEnd(visibleUpTo: 0.93, storyEnd: 0.93)
          && !BookEnding.showsEnd(visibleUpTo: 0.92, storyEnd: 0.93))

    check("an audiobook in its closing credits is heard", BookEnding.heardShare(position: 7120, duration: 7200, storyEnd: 7100) == 1)
    check("…and in its last half minute", BookEnding.heardShare(position: 7175, duration: 7200, storyEnd: nil) == 1)
    check("…but not before", abs(BookEnding.heardShare(position: 3600, duration: 7200, storyEnd: 7100) - 0.5) < 1e-9)

    let id = UUID(), other = UUID()
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = [
        ReadingSession(bookID: id, title: "X", end: start, minutes: 30, progressStart: 0, progressEnd: 0.2, audio: false),
        ReadingSession(bookID: id, title: "X", end: start.addingTimeInterval(day), minutes: 90, progressStart: 0.2, progressEnd: 0.7, audio: false),
        ReadingSession(bookID: id, title: "X", end: start.addingTimeInterval(day + 3600), minutes: 252, progressStart: 0.7, progressEnd: 1, audio: false),
        ReadingSession(bookID: other, title: "Y", end: start, minutes: 500, progressStart: 0, progressEnd: 1, audio: false),
    ]
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let summary = BookEnding.summary(of: sessions, book: id, calendar: utc)
    check("the time a book took, its own sittings only", summary?.line == "6 h 12 min over 2 days · 3 sittings", summary?.line ?? "nil")
    check("…from when its first sitting began", summary?.started == start.addingTimeInterval(-30 * 60))
    check("no sittings, nothing to say", BookEnding.summary(of: [], book: id) == nil)
    check("a short book in minutes", BookEnding.Summary.duration(42) == "42 min" && BookEnding.Summary.duration(120) == "2 h")

    let done = ending("Find Me Where It Ends", "Cassandra Khaw", read: 1)
    let library = [
        done,
        ending("Find Me Where It Ends", "Cassandra Khaw", audio: true),
        ending("The Salt Grows Heavy", "Cassandra Khaw", read: 0.3),
        ending("Nothing But Blackened Teeth", "Khaw, Cassandra"),
        ending("Hammers on Bone", "Cassandra Khaw", read: 1),
        ending("Dune", "Frank Herbert"),
    ]
    let more = BookEnding.moreBy(done, in: library).map(\.title)
    check("more by the author: not started first, then under way; not finished, not its own other edition",
          more == ["Nothing But Blackened Teeth", "The Salt Grows Heavy"], more.joined(separator: ", "))
    check("no author, no more by", BookEnding.moreBy(ending("Untitled", ""), in: library).isEmpty)
}
