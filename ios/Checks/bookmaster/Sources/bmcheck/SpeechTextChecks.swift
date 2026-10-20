import Foundation

func runSpeechTextChecks() {
    section("Read-aloud text flow")
    check("printed line breaks become spaces",
          SpeechText.spoken("There were far too\nmany stops in this line.") == "There were far too many stops in this line.")
    check("words hyphenated across printed lines are rejoined",
          SpeechText.spoken("The extraor-\ndinary answer") == "The extraordinary answer")
    check("real compound words keep their hyphen",
          SpeechText.spoken("A well-known answer") == "A well-known answer")
    check("soft hyphens and ebook ligatures do not reach the voice",
          SpeechText.spoken("dif\u{00AD}ﬁcult ﬂowers") == "difficult flowers")
    check("unambiguous abbreviations are spoken naturally",
          SpeechText.spoken("Use it, e.g. here, vs. there, etc.") == "Use it, for example here, versus there, et cetera.")
    check("footnote markers are not read out",
          SpeechText.spoken("It was over.¹ She left.[2]") == "It was over. She left.")
    check("a sentence ending in etc. keeps its full stop",
          SpeechText.spoken("Pens, ink, etc.") == "Pens, ink, et cetera.")
    check("etc. in the middle of a sentence stays there",
          SpeechText.spoken("pens, etc. and more") == "pens, et cetera and more")
    check("a year range is spoken as a range",
          SpeechText.spoken("the war of 1914–1918") == "the war of nineteen fourteen to nineteen eighteen")
    check("a hyphenated number is left alone",
          SpeechText.spoken("call 555-1234") == "call 555-1234")
    check("a chapter's roman numeral is a number",
          SpeechText.spoken("Chapter XIV") == "Chapter 14")
    check("an all-caps heading too",
          SpeechText.spoken("CHAPTER IV.") == "CHAPTER 4.")
    check("a roman numeral alone as a heading",
          SpeechText.spoken("XLII") == "42")
    check("a heading numeral keeps its full stop",
          SpeechText.spoken("XII.") == "12.")
    check("a word spelled in roman letters is left alone",
          SpeechText.spoken("Chapter DID") == "Chapter DID")
    check("I alone is a pronoun", SpeechText.spoken("I") == "I")
    check("a lower-case numeral is a word", SpeechText.spoken("Chapter xiv") == "Chapter xiv")
    check("roman values",
          SpeechText.romanValue("MCMXCIV") == 1994 && SpeechText.romanValue("IIII") == nil
              && SpeechText.romanValue("") == nil && SpeechText.romanValue("MIMIC") == nil)
    check("a title before a space does not end the sentence",
          SpeechText.shouldJoin(previous: "She asked Dr.", separator: " ", next: "Morgan to stay."))
    check("a lower-case continuation is the same sentence",
          SpeechText.shouldJoin(previous: "I thought…", separator: " ", next: "maybe not."))
    check("a capital after a full stop on one line is a new sentence",
          !SpeechText.shouldJoin(previous: "It ended.", separator: " ", next: "Another began."))
    check("nothing between two pieces is not a join",
          !SpeechText.shouldJoin(previous: "It ended.", separator: "", next: "another"))
    check("a wrapped clause remains one utterance",
          SpeechText.shouldJoin(previous: "There was still", separator: "\n", next: "more to say."))
    check("a real sentence ending stays separate",
          !SpeechText.shouldJoin(previous: "It ended.", separator: "\n", next: "Another began."))
    check("a title at a line end does not strand the name",
          SpeechText.shouldJoin(previous: "She asked Dr.", separator: "\n", next: "Morgan to stay."))
    check("layout spaces alone do not merge sentences",
          !SpeechText.shouldJoin(previous: "It ended.", separator: "   ", next: "Another began."))

    section("Read-aloud word ranges back onto the page")
    /// The word `word` as the voice reports it in the cleaned text, found again in `original`.
    func backOnPage(_ original: String, _ word: String) -> String? {
        let spoken = SpeechText.spoken(original)
        guard let r = spoken.range(of: word) else { return "<\(word) not in spoken: \(spoken)>" }
        return SpeechText.originalRange(of: r, spoken: spoken, original: original).map { String(original[$0]) }
    }
    check("unchanged text maps onto itself",
          backOnPage("Hello there, friend.", "there") == "there")
    check("after a soft hyphen the word is still found",
          backOnPage("The extra\u{00AD}ordinary answer came.", "answer") == "answer")
    check("the hyphenated word itself is found whole",
          backOnPage("The extra\u{00AD}ordinary answer came.", "extraordinary") == "extra\u{00AD}ordinary")
    check("after a ligature the word is still found",
          backOnPage("diﬃcult ﬂowers bloom", "bloom") == "bloom")
    check("the ligature word maps onto its printed form",
          backOnPage("diﬃcult ﬂowers bloom", "flowers") == "ﬂowers")
    check("after an abbreviation spelled out the word is found",
          backOnPage("Use it, e.g. here now", "now") == "now")
    check("a word the page never had has no range",
          backOnPage("Use it, e.g. here now", "example") == nil)
    check("a year range said in words has no word on the page, and what follows still maps",
          backOnPage("the war of 1914–1918 ended", "eighteen") == nil
              && backOnPage("the war of 1914–1918 ended", "ended") == "ended")
    check("after a footnote marker the word is found",
          backOnPage("It was over.¹ She left.", "left") == "left")
    check("after a chapter numeral the word is found",
          backOnPage("Chapter XIV Morning", "Morning") == "Morning")
    check("punctuation alone has no range",
          backOnPage("Well, then.", ",") == nil)

    section("Read-aloud dates")
    func said(_ t: String) -> String { SpeechText.spoken(t) }
    check("an ISO date", said("It was 1984-05-12.") == "It was May twelfth, nineteen eighty-four.", said("It was 1984-05-12."))
    check("a slash date with a day over 12", said("On 25/12/2023 we met.") == "On December twenty-fifth, 2023 we met.", said("On 25/12/2023 we met."))
    check("a slash date with a second part over 12", said("On 12/25/2023 we met.") == "On December twenty-fifth, 2023 we met.", said("On 12/25/2023 we met."))
    check("a year after a month", said("In May 1805 he left.") == "In May eighteen oh five he left.", said("In May 1805 he left."))
    check("a month, day and year", said("March 5, 1999") == "March 5, nineteen ninety-nine", said("March 5, 1999"))
    check("a year after in", said("He was born in 1900.") == "He was born in nineteen hundred.", said("He was born in 1900."))
    check("a year after in that is a count is left to the voice when it is not a year", said("in 2005") == "in 2005")
    check("an abbreviated month", said("Sept. 11 was a Tuesday.") == "September 11 was a Tuesday.", said("Sept. 11 was a Tuesday."))
    check("a span of years", said("The war of 1914-1918 ended.") == "The war of nineteen fourteen to nineteen eighteen ended.", said("The war of 1914-1918 ended."))
    check("a decade", said("the 1990s") == "the nineteen nineties" && said("the 1960's") == "the nineteen sixties", said("the 1990s"))
    check("a decade of the two thousands", said("the 2010s and 2000s") == "the twenty tens and two thousands", said("the 2010s and 2000s"))
    check("a short decade", said("back in the '80s") == "back in the eighties", said("back in the '80s"))
    check("a plain number is left alone", said("He had 1500 men and 12 horses.") == "He had 1500 men and 12 horses.")
    check("a number that is not a date with a slash is left alone", said("a ratio of 3/4 holds") == "a ratio of 3/4 holds")
}
