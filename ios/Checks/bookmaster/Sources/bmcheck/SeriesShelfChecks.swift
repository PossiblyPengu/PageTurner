import Foundation

private func volume(_ title: String, _ series: String?, _ index: Double?, read: Double? = nil,
                    audio: Bool = false, opened: Date? = nil) -> Book {
    let file = audio ? "\(title).m4b" : "\(title).epub"
    var b = Book(id: UUID(), title: title, author: "", fileName: file, fileNames: [file], addedAt: Date())
    b.series = series
    b.seriesIndex = index
    b.progression = read
    b.lastOpenedAt = opened
    return b
}

/// Series together (`SeriesShelf`): in reading order, counted by volume, and the book that comes next.
func runSeriesShelfChecks() {
    section("Series")
    let dune1 = volume("Dune", "Dune", 1, read: 1, opened: Date(timeIntervalSince1970: 100))
    let dune1Audio = volume("Dune", "Dune", 1, audio: true)
    let dune2 = volume("Dune Messiah", "Dune", 2)
    let dune2Audio = volume("Dune Messiah", "dune", 2, audio: true)
    let dune3 = volume("Children of Dune", "Dune ", 3)
    let wind = volume("The Name of the Wind", "The Kingkiller Chronicle", 1, read: 0.4, opened: Date(timeIntervalSince1970: 500))
    let fear = volume("The Wise Man's Fear", "Kingkiller Chronicle", 2)
    let alone = volume("Kitchen Confidential", nil, nil)
    let groups = SeriesShelf.groups([dune3, alone, fear, dune2Audio, dune1Audio, wind, dune2, dune1])

    check("one group per series, however it is spelled", groups.count == 2, "\(groups.map(\.name))")
    check("the series read most lately first", groups.first?.name == "The Kingkiller Chronicle", groups.first?.name ?? "")
    let dune = groups.first { $0.key == SeriesShelf.key("Dune") }
    check("in reading order, the ebook before its audiobook",
          dune?.books.map(\.id) == [dune1.id, dune1Audio.id, dune2.id, dune2Audio.id, dune3.id],
          dune?.books.map(\.title).joined(separator: ", ") ?? "")
    check("counted by volume, and read when either edition is", dune?.volumes == 3 && dune?.finished == 1,
          "\(dune?.volumes ?? -1) / \(dune?.finished ?? -1)")
    check("next is the volume after the furthest read", dune?.next?.title == "Dune Messiah", dune?.next?.title ?? "nil")
    check("with nothing read, the one under way", groups.first?.next?.id == wind.id)
    check("the name most books use", dune?.name == "Dune", dune?.name ?? "")

    let all = [dune1, dune1Audio, dune2, dune2Audio, dune3, alone]
    check("after an ebook, the next ebook", SeriesShelf.next(after: dune1, in: all)?.id == dune2.id)
    check("after an audiobook, the next audiobook", SeriesShelf.next(after: dune1Audio, in: all)?.id == dune2Audio.id)
    check("a volume already read is passed over",
          SeriesShelf.next(after: dune1, in: [dune1, volume("Dune Messiah", "Dune", 2, read: 1), dune3])?.id == dune3.id)
    check("the last of a series has no next", SeriesShelf.next(after: dune3, in: all) == nil)
    check("a book in no series has no next", SeriesShelf.next(after: alone, in: all) == nil)
    var done = dune3
    done.progression = 1
    check("every volume read, nothing next", SeriesShelf.groups([dune1, volume("Dune Messiah", "Dune", 2, read: 1), done]).first?.next == nil)

    check("where a book sits", SeriesShelf.place(of: dune2) == "Book 2 of Dune"
          && SeriesShelf.place(of: volume("Novella", "Dune", 2.5)) == "Book 2.5 of Dune"
          && SeriesShelf.place(of: volume("Extra", "Dune", nil)) == "Dune"
          && SeriesShelf.place(of: alone) == nil)
}
