import Foundation

private func edition(_ title: String, _ author: String, audio: Bool, opened: Date? = nil) -> Book {
    let file = audio ? "\(title).m4b" : "\(title).epub"
    var b = Book(id: UUID(), title: title, author: author, fileName: file, fileNames: [file], addedAt: Date())
    b.lastOpenedAt = opened
    return b
}

/// The ebook and the audiobook of one book (`Companion`): finding the other, and the same place in it.
func runCompanionChecks() {
    section("Ebook and audiobook together")
    let ebook = edition("Project Hail Mary", "Andy Weir", audio: false)
    let audio = edition("Project Hail Mary (Unabridged)", "Weir, Andy", audio: true)
    let other = edition("The Martian", "Andy Weir", audio: true)
    let stranger = edition("Project Hail Mary", "Someone Else", audio: true)
    let books = [ebook, audio, other, stranger]
    check("the ebook finds its audiobook", Companion.match(for: ebook, in: books)?.id == audio.id,
          Companion.match(for: ebook, in: books)?.title ?? "nil")
    check("and the audiobook its ebook", Companion.match(for: audio, in: books)?.id == ebook.id)
    check("another book by the author is not it, nor the same title by another", Companion.match(for: other, in: books) == nil)
    let twin = edition("Project Hail Mary", "Andy Weir", audio: true)
    check("the very same title wins over one that only agrees", Companion.match(for: ebook, in: books + [twin])?.id == twin.id)

    check("chapter names fold together", Companion.chapterKey("Chapter Three") == "3"
          && Companion.chapterKey("03 - Chapter 3") == "3" && Companion.chapterKey("CHAPTER III") == "3"
          && Companion.chapterKey("Chapter Twenty-One") == "21" && Companion.chapterKey("01 Prologue") == "prologue")
    check("a word that only looks like a numeral stays a word", Companion.chapterKey("I Am Legend") == "i am legend"
          && Companion.chapterKey("Mix") == "mix")

    // the ebook: front matter, then three chapters; the audiobook: credits, then the same three
    let page: [Companion.Mark] = [.init(title: "Title Page", start: 0), .init(title: "Dedication", start: 0.01),
                                  .init(title: "Chapter One", start: 0.02), .init(title: "Chapter Two", start: 0.40),
                                  .init(title: "Chapter Three", start: 0.70)]
    let tracks: [Companion.Mark] = [.init(title: "Opening Credits", start: 0), .init(title: "01 - Chapter 1", start: 30),
                                    .init(title: "02 - Chapter 2", start: 4_000), .init(title: "03 - Chapter 3", start: 7_000)]
    let reading = Companion.place(at: 0.55, in: page, end: 1)
    check("a place on the page: its chapter and how far in", reading.chapter == "Chapter Two" && abs(reading.fraction - 0.5) < 1e-9
          && abs(reading.overall - 0.55) < 1e-9, "\(reading)")
    let heard = Companion.locate(reading, in: tracks, end: 10_000)
    check("…is as far into the chapter of the same name in the audiobook", abs(heard - 5_500) < 1e-6, "\(heard)")
    let back = Companion.locate(Companion.place(at: 5_500, in: tracks, end: 10_000), in: page, end: 1)
    check("and back again to the same place on the page", abs(back - 0.55) < 1e-9, "\(back)")
    let unnamed = Companion.locate(Companion.Place(chapter: "Afterword", fraction: 0.5, overall: 0.9), in: tracks, end: 10_000)
    check("a chapter the other has no name for: the same share of the whole", abs(unnamed - 9_000) < 1e-6, "\(unnamed)")
    check("no chapters at all: the same share", abs(Companion.locate(Companion.Place(chapter: nil, fraction: 0, overall: 0.25), in: [], end: 400) - 100) < 1e-9)

    let parts: [Companion.Mark] = [.init(title: "Prologue", start: 0), .init(title: "Part 1", start: 0.1),
                                   .init(title: "Prologue", start: 0.5), .init(title: "Part 2", start: 0.6)]
    let second = Companion.locate(Companion.Place(chapter: "Prologue", fraction: 0, overall: 0.52), in: parts, end: 1)
    check("two of one name: the one nearest the same share", abs(second - 0.5) < 1e-9, "\(second)")
    let titled = Companion.locate(Companion.Place(chapter: "Chapter 2", fraction: 0, overall: 0.4),
                                  in: [.init(title: "Hail Mary: Chapter 1", start: 0), .init(title: "Hail Mary: Chapter 2", start: 60)], end: 120)
    check("a name with the book's in front of it is still that chapter", abs(titled - 60) < 1e-9, "\(titled)")
}
