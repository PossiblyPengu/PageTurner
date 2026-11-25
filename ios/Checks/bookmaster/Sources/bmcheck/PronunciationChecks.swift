import Foundation

/// Words the reader taught the voice (`Pronunciations`), put in what it says (`SpeechText.spoken`) with the
/// marks still on the printed words (`SpeechText.WordMap`).
func runPronunciationChecks() {
    section("Pronunciations")
    let book = UUID(), other = UUID()
    let taught = [
        Pronunciation(written: "Hermione", said: "her-MY-oh-nee"),
        Pronunciation(written: "Minas Tirith", said: "MEE-nas TEE-rith"),
        Pronunciation(written: "Sean", said: "Shawn", bookID: book),
        Pronunciation(written: "Hermione", said: "her-mee-OWN", bookID: other),
    ]
    let before = Pronunciations.generation
    Pronunciations.use(taught, book: book)
    check("teaching changes the generation the cache is keyed on", Pronunciations.generation != before)

    let said = SpeechText.spoken("Hermione smiled.")
    check("a taught word is said as taught", said == "her-MY-oh-nee smiled.", said)
    check("in any case", SpeechText.spoken("HERMIONE!") == "her-MY-oh-nee!", SpeechText.spoken("HERMIONE!"))
    check("a possessive keeps its ’s", SpeechText.spoken("Hermione’s wand.") == "her-MY-oh-nee’s wand.",
          SpeechText.spoken("Hermione’s wand."))
    check("not inside another word", SpeechText.spoken("Hermiones and Seance.") == "Hermiones and Seance.",
          SpeechText.spoken("Hermiones and Seance."))
    check("a name of two words, across a printed line", SpeechText.spoken("They rode to Minas\nTirith.") == "They rode to MEE-nas TEE-rith.",
          SpeechText.spoken("They rode to Minas\nTirith."))
    check("a book's own word is said in that book", SpeechText.spoken("Sean ran.") == "Shawn ran.", SpeechText.spoken("Sean ran."))

    Pronunciations.use(taught, book: other)
    check("…and not in another", SpeechText.spoken("Sean ran.") == "Sean ran.", SpeechText.spoken("Sean ran."))
    check("a book's own wins over every book's", SpeechText.spoken("Hermione.") == "her-mee-OWN.", SpeechText.spoken("Hermione."))

    // the marks: every part of what is said for a taught word lands on the word as printed
    Pronunciations.use(taught, book: book)
    let original = "Hermione smiled at Sean."
    let spoken = SpeechText.spoken(original)
    let map = SpeechText.WordMap(spoken: spoken, original: original)
    func mark(_ word: String) -> String? {
        guard let range = spoken.range(of: word) else { return nil }
        return map.originalRange(of: range).map { String(original[$0]) }
    }
    check("the first part of a taught word marks it", mark("her") == "Hermione", mark("her") ?? "nil")
    check("…and so does the last", mark("nee") == "Hermione", mark("nee") ?? "nil")
    check("the words after it still mark themselves", mark("smiled") == "smiled" && mark("at") == "at")
    check("a word said another way marks the printed one", mark("Shawn") == "Sean", mark("Shawn") ?? "nil")

    check("an entry is a word or a few, tidied", Pronunciations.cleaned("  Hermione, ") == "Hermione"
          && Pronunciations.cleaned("Minas   Tirith") == "Minas Tirith")
    check("not a passage, and not nothing", Pronunciations.cleaned("one two three four five") == nil
          && Pronunciations.cleaned("  ") == nil && Pronunciations.cleaned("1984") == nil)
    check("two spellings of an entry are one", Pronunciations.key("Minas  Tirith") == Pronunciations.key("minas tirith")
          && Pronunciations.key("D’Artagnan") == Pronunciations.key("d'artagnan"))

    Pronunciations.use([], book: nil)
    check("taught nothing, the text is as it was", SpeechText.spoken("Hermione smiled.") == "Hermione smiled.")
}
