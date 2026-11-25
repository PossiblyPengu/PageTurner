import Foundation

/// What the on-device model is given for "The Story So Far" and "Who's This?" (`StoryRecap`): never past the
/// reader's place, in pieces it can take.
func runStoryRecapChecks() {
    section("Story so far and who's this")
    let text = "Paul woke early. The house was quiet! Jessica watched him? He said nothing. Then the duke came."
    let half = StoryRecap.upTo(0.5, of: text)
    check("cut at the reader's place, after the last whole sentence", half == "Paul woke early. The house was quiet!", half)
    check("all of it at the end, none at the start", StoryRecap.upTo(1, of: text) == text && StoryRecap.upTo(0, of: text) == "")
    let quoted = StoryRecap.upTo(0.6, of: "“Go now.” She went. And then the night fell over them all.")
    check("a closing quote stays with its sentence", quoted == "“Go now.” She went.", quoted)

    let paragraphs = (1 ... 30).map { "Paragraph \($0) " + String(repeating: "word ", count: 60) }.joined(separator: "\n\n")
    let pieces = StoryRecap.pieces(of: paragraphs, limit: 2_000)
    check("pieces no longer than asked", pieces.allSatisfy { $0.count <= 2_000 }, "\(pieces.map(\.count))")
    check("cut between paragraphs", pieces.dropLast().allSatisfy { $0.hasSuffix("word") } && pieces.count > 1)
    check("nothing lost", pieces.joined(separator: " ").split(separator: " ").count == paragraphs.split(whereSeparator: \.isWhitespace).count)
    let unbroken = String(repeating: "a", count: 5_000)
    check("text with nowhere to cut is still cut", StoryRecap.pieces(of: unbroken, limit: 2_000).map(\.count) == [2_000, 2_000, 1_000])
    check("a short text is one piece", StoryRecap.pieces(of: "Short.") == ["Short."])

    let chapters = [
        (title: "One", text: "Ned Stark rode north. The wolves howled. Ned was tired."),
        (title: "Two", text: "Arya asked about Ned. Nedra smiled. The king rode south."),
    ]
    let ned = StoryRecap.mentions(of: "Ned", in: chapters)
    check("the sentences that name them, with their chapter", ned == ["(One) Ned Stark rode north.", "(One) Ned was tired.", "(Two) Arya asked about Ned."],
          ned.joined(separator: " | "))
    let full = StoryRecap.mentions(of: "Ned Stark", in: chapters)
    check("a full name met once is looked for by its words too", full.count == 3, full.joined(separator: " | "))
    check("not inside another name", !ned.contains { $0.contains("Nedra") })
    let many = (1 ... 50).map { (title: "C\($0)", text: "Ned did thing \($0).") }
    let picked = StoryRecap.mentions(of: "Ned", in: many, limit: 9)
    check("the first few and then the latest", picked.count == 9 && picked.first == "(C1) Ned did thing 1." && picked.last == "(C50) Ned did thing 50."
          && picked[3] == "(C45) Ned did thing 45.", picked.joined(separator: " | "))

    let recaps = (1 ... 40).map { (chapter: "Chapter \($0)", summary: String(repeating: "Things happened. ", count: 20)) }
    let story = StoryRecap.storyPrompt(book: "Dune", recaps: recaps)
    check("too many recaps for one request: the latest are kept", story.contains("Chapter 40:") && !story.contains("Chapter 1:")
          && story.contains("latest chapters") && story.count < StoryRecap.pieceLength + 400)
    check("a few recaps go whole", StoryRecap.storyPrompt(book: "Dune", recaps: Array(recaps.prefix(2))).contains("Chapter 1:"))
    check("sentences, spaces closed up", StoryRecap.sentences(in: "One.  Two!\nThree   four? “Five.” Six") == ["One.", "Two!", "Three four?", "“Five.”", "Six"],
          StoryRecap.sentences(in: "One.  Two!\nThree   four? “Five.” Six").joined(separator: "|"))
}
