import Foundation

/// Saved words studied (`WordStudy`): Wiktionary's answer read down to a line, and the review's boxes.
func runWordStudyChecks() {
    section("Saved words: definitions and review")
    let answer = """
    {"en":[{"partOfSpeech":"Adjective","language":"English","definitions":[
      {"definition":"<span>Gloomy</span>; <a href=\\"/wiki/dismal\\">dismal</a>.","examples":["a sullen sky"]},
      {"definition":"Showing ill humour."}]},
      {"partOfSpeech":"Noun","language":"English","definitions":[{"definition":"A sullen person."}]}],
     "fr":[{"partOfSpeech":"Adjectif","language":"French","definitions":[{"definition":"Maussade."}]}]}
    """
    check("the first sense, and the next when the first is short, tags gone",
          WordStudy.definition(fromWiktionary: Data(answer.utf8)) == "adjective: Gloomy; dismal. Showing ill humour.",
          WordStudy.definition(fromWiktionary: Data(answer.utf8)) ?? "nil")
    check("in the book's language when it has one",
          WordStudy.definition(fromWiktionary: Data(answer.utf8), language: "fr") == "adjectif: Maussade.",
          WordStudy.definition(fromWiktionary: Data(answer.utf8), language: "fr") ?? "nil")
    let empty = #"{"en":[{"partOfSpeech":"Noun","definitions":[{"definition":""}]}]}"#
    check("an answer with no sense says there is none", WordStudy.definition(fromWiktionary: Data(empty.utf8)) == "")
    check("no answer at all is not 'none'", WordStudy.definition(fromWiktionary: Data("<html>".utf8)) == nil)
    let long = "{\"en\":[{\"partOfSpeech\":\"Noun\",\"definitions\":[{\"definition\":\"" + String(repeating: "word ", count: 80) + "\"}]}]}"
    let cut = WordStudy.definition(fromWiktionary: Data(long.utf8)) ?? ""
    check("a long sense is cut at a word", cut.hasSuffix("…") && cut.count <= WordStudy.longestDefinition + 7 && !cut.contains("wor…"), cut)
    check("a phrase's address", WordStudy.wiktionaryPath(for: " in  lieu of ") == "in_lieu_of"
          && WordStudy.wiktionaryPath(for: "naïve") == "na%C3%AFve" && WordStudy.wiktionaryPath(for: "a/b") == "a%2Fb")

    let now = Date(timeIntervalSince1970: 1_000_000)
    var word = SavedWord(word: "sullen", createdAt: now.addingTimeInterval(-500))
    check("a word never reviewed is due", WordStudy.isDue(word, now: now))
    word = WordStudy.graded(word, knew: true, now: now)
    check("known once: a day away", word.box == 1 && word.dueAt == now.addingTimeInterval(86_400) && !WordStudy.isDue(word, now: now))
    word = WordStudy.graded(word, knew: true, now: now)
    check("known twice: three days", word.box == 2 && word.dueAt == now.addingTimeInterval(3 * 86_400))
    word = WordStudy.graded(word, knew: false, now: now)
    check("not known: back to the start, due at once", word.box == 0 && WordStudy.isDue(word, now: now))
    for _ in 0 ..< 8 { word = WordStudy.graded(word, knew: true, now: now) }
    check("known every time: learned, ninety days at most", WordStudy.isLearned(word) && word.dueAt == now.addingTimeInterval(90 * 86_400))

    let old = SavedWord(word: "old", createdAt: now.addingTimeInterval(-9000))
    let fresh = SavedWord(word: "fresh", createdAt: now.addingTimeInterval(-10))
    var waiting = SavedWord(word: "waiting", createdAt: now)
    waiting.dueAt = now.addingTimeInterval(-5000)
    var later = SavedWord(word: "later", createdAt: now)
    later.dueAt = now.addingTimeInterval(5000)
    check("the due ones, longest waiting first", WordStudy.due([fresh, later, waiting, old], now: now).map(\.word) == ["old", "waiting", "fresh"],
          WordStudy.due([fresh, later, waiting, old], now: now).map(\.word).joined(separator: ","))
    check("and no more than asked", WordStudy.due([fresh, waiting, old], now: now, limit: 2).count == 2)
}
