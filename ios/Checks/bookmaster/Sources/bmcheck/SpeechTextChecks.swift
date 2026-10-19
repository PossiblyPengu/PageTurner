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
          SpeechText.spoken("the war of 1914–1918") == "the war of 1914 to 1918")
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
}
