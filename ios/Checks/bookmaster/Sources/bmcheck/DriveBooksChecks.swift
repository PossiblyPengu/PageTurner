import Foundation

private func file(_ id: String, _ name: String, size: Int64? = nil) -> GoogleDrive.File {
    GoogleDrive.File(id: id, name: name, mimeType: "application/octet-stream", size: size)
}

private func found(_ id: String, _ name: String, in folder: String = "", size: Int64? = nil) -> DriveBooks.Found {
    DriveBooks.Found(file(id, name, size: size), folder: folder)
}

func runDriveBooksChecks() {
    section("Drive books: what is added without being downloaded")

    // ebooks: one book per file, named from the file; what has to be opened first is left for a download
    let mixed = DriveBooks.plan([
        found("1", "Dune.epub", in: "SciFi", size: 1_000),
        found("2", "Manual.pdf"),
        found("3", "Comic 1.cbz"),
        found("4", "Notes.txt"),
        found("5", "Archive.zip"),
        found("6", "photo.jpg"),
    ], known: [])
    check("an epub, a pdf and a cbz are books", mixed.books.map(\.title) == ["Comic 1", "Dune", "Manual"], "\(mixed.books.map(\.title))")
    check("their source is the Drive file, in one part",
          mixed.books.allSatisfy { $0.source.parts.count == 1 && !$0.isAudio && $0.trackTitles.isEmpty })
    check("a text file and a zip must be downloaded to be books", Set(mixed.direct.map(\.file.id)) == ["4", "5"])
    check("a file that is no book is ignored", !mixed.direct.contains { $0.file.id == "6" } && mixed.known == 0)
    check("the first guess at a title is kept to tell a changed one later",
          mixed.books.allSatisfy { $0.source.guessedTitle == $0.title && !$0.source.finished })

    let again = DriveBooks.plan([found("1", "Dune.epub"), found("2", "Manual.pdf")], known: ["1"])
    check("a file the library already holds is not added again", again.books.map(\.title) == ["Manual"] && again.known == 1)

    // audiobooks: folders and file-name stems decide what is one book
    let one = DriveBooks.plan([
        found("a3", "ch10.mp3", in: "Dune"), found("a1", "ch1.mp3", in: "Dune"), found("a2", "ch2.mp3", in: "Dune"),
    ], known: [])
    check("a folder of tracks is one audiobook named for the folder", one.books.count == 1 && one.books[0].title == "Dune"
          && one.books[0].isAudio, "\(one.books.map(\.title))")
    check("its tracks play in natural order, ch2 before ch10", one.books[0].source.parts.map(\.id) == ["a1", "a2", "a3"],
          "\(one.books[0].source.parts.map(\.id))")
    check("track titles are the file names", one.books[0].trackTitles == ["ch1", "ch2", "ch10"], "\(one.books[0].trackTitles)")

    let discs = DriveBooks.plan([
        found("d2", "01.mp3", in: "Dune/CD 2"), found("d1", "01.mp3", in: "Dune/CD 1"), found("d3", "02.mp3", in: "Dune/CD 1"),
    ], known: [])
    check("CD folders merge into one book named for their parent", discs.books.count == 1 && discs.books[0].title == "Dune",
          "\(discs.books.map(\.title))")
    check("the parts keep their disc order", discs.books[0].source.parts.map(\.id) == ["d1", "d3", "d2"],
          "\(discs.books[0].source.parts.map(\.id))")
    check("a track that shares its name with one on another disc says which disc",
          discs.books[0].trackTitles == ["CD 1 — 01", "CD 1 — 02", "CD 2 — 01"], "\(discs.books[0].trackTitles)")

    let two = DriveBooks.plan([
        found("x1", "Dune - 01.mp3", in: "Audio"), found("x2", "Dune - 02.mp3", in: "Audio"),
        found("y1", "Emma - 01.mp3", in: "Audio"), found("y2", "Emma - 02.mp3", in: "Audio"),
    ], known: [])
    check("two books in one folder stay two", two.books.count == 2, "\(two.books.map(\.title))")

    let lone = DriveBooks.plan([found("l", "The Hobbit.m4b", in: "Audiobooks")], known: [])
    check("a lone file is named for itself, not for the folder it shares", lone.books.map(\.title) == ["The Hobbit"],
          "\(lone.books.map(\.title))")

    let rootFiles = DriveBooks.plan([found("r1", "Part 1.mp3"), found("r2", "Part 2.mp3")], known: [])
    check("tracks at the top of the Drive are not named for the root", rootFiles.books.allSatisfy { $0.title != "/" && !$0.title.isEmpty },
          "\(rootFiles.books.map(\.title))")

    let known = DriveBooks.plan([found("a1", "ch1.mp3", in: "Dune"), found("a2", "ch2.mp3", in: "Dune")], known: ["a1"])
    check("a book with any part already in the library is not made again", known.books.isEmpty || known.books[0].source.parts.count == 1,
          "\(known.books.map(\.source.parts.count))")

    check("the folder rule skips a dump folder", AudioGrouping.folderTitle(for: [
        URL(fileURLWithPath: "/Downloads/a.mp3"), URL(fileURLWithPath: "/Downloads/b.mp3")]) == nil)
    check("and takes a folder somebody named", AudioGrouping.folderTitle(for: [
        URL(fileURLWithPath: "/Dune/a.mp3"), URL(fileURLWithPath: "/Dune/b.mp3")]) == "Dune")

    // the files it will be once down
    let id = UUID()
    let epub = GoogleDrive.FileRef(id: "e", name: "Dune.EPUB")
    let track = GoogleDrive.FileRef(id: "t", name: "01.MP3")
    check("a book's one file is <id>.<ext>", DriveBooks.localName(book: id, index: 0, part: epub, audio: false) == "\(id.uuidString).epub")
    check("an audiobook's parts are <id>-<n>.<ext>", DriveBooks.localName(book: id, index: 3, part: track, audio: true) == "\(id.uuidString)-3.mp3")
    check("a part with no extension has none", DriveBooks.localName(book: id, index: 0, part: GoogleDrive.FileRef(id: "n", name: "Dune"), audio: false) == id.uuidString)

    // what is still to come
    let source = GoogleDrive.Source(
        parts: [GoogleDrive.FileRef(id: "1", name: "a.mp3", size: 100), GoogleDrive.FileRef(id: "2", name: "b.mp3", size: 200),
                GoogleDrive.FileRef(id: "3", name: "c.mp3")],
        guessedTitle: "X")
    check("a source adds up its parts", source.bytes == 300)
    let names = ["a", "b", "c"]
    check("parts that are there at their full size are done", DriveBooks.pending(source, names: names, size: { _ in nil }) == [0, 1, 2])
    check("only the missing ones are left", DriveBooks.pending(source, names: names, size: { ["a": 100, "c": 5][$0] }) == [1])
    check("a part of the wrong size is still to come", DriveBooks.pending(source, names: names, size: { ["a": 40, "b": 200, "c": 9][$0] }) == [0])
    check("a part Drive gave no size for is done once it is there", DriveBooks.pending(source, names: names, size: { _ in 123 }) == [0, 1])
    check("progress is a fraction, nothing without a size", DriveBooks.fraction(received: 50, total: 200) == 0.25
          && DriveBooks.fraction(received: 5, total: 0) == nil && DriveBooks.fraction(received: 500, total: 200) == 1)

    // the catalogue keeps where a book comes from
    var book = Book(id: UUID(), title: "Dune", author: "", fileName: "\(id.uuidString).epub", fileNames: ["\(id.uuidString).epub"], addedAt: Date())
    book.drive = GoogleDrive.Source(parts: [epub], guessedTitle: "Dune")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    if let data = try? encoder.encode([book]), let back = try? JSONDecoder().decode([Book].self, from: data) {
        check("a Drive book keeps its source through the catalogue", back.first?.drive == book.drive && back.first?.drive?.parts.first?.name == "Dune.EPUB")
    } else {
        check("a Drive book keeps its source through the catalogue", false, "did not encode and decode")
    }
    var plain = book
    plain.drive = nil
    if let data = try? encoder.encode([plain]), let back = try? JSONDecoder().decode([Book].self, from: data) {
        check("a book from anywhere else has no source", back.first?.drive == nil)
    } else {
        check("a book from anywhere else has no source", false, "did not encode and decode")
    }
}
