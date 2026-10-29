import Foundation

// Checks for the read-aloud highlight options: which words a sentence is made of, when each is
// spoken (for voices that give no word positions), where the speech sits in the audio, and the
// stored choices. No servers needed.

private func words(_ text: String, split: ((String) -> [Range<String.Index>])? = nil) -> [String] {
    SpokenWords.tokens(in: text, split: split).map { String(text[$0.range]) }
}

@MainActor
func runSpokenWordsChecks() {
    section("Highlights: the words of a sentence")
    check("words come without the punctuation round them", words("Hello, world!") == ["Hello", "world"])
    check("quotes, brackets and dashes are not part of a word",
          words("“Oh dear!” she said — (quietly).") == ["Oh", "dear", "she", "said", "quietly"], "\(words("“Oh dear!” she said — (quietly)."))")
    check("an apostrophe or hyphen inside a word stays", words("It isn’t well-known, is it?") == ["It", "isn’t", "well-known", "is", "it"])
    check("digits are words", words("In 1999, at 3.5%") == ["In", "1999", "at", "3.5"])
    check("nothing but punctuation is no word at all", words("— … —").isEmpty && words("").isEmpty)
    check("newlines and tabs separate words", words("one\ntwo\tthree  four") == ["one", "two", "three", "four"])
    check("an em dash with no spaces round it divides two words", words("Some years ago—never mind how long—having little money") ==
          ["Some", "years", "ago", "never", "mind", "how", "long", "having", "little", "money"], "\(words("Some years ago—never mind how long—having little money"))")
    check("…and is a pause after the first of them", {
        let text = "ago—never"
        return SpokenWords.tokens(in: text).map(\.pause) == [.clause, .none]
    }())
    check("a dash that starts a word, two together, or one at the end do not make empty words",
          words("—and then") == ["and", "then"] && words("ago——never") == ["ago", "never"] && words("wait—") == ["wait"])
    check("an en dash in a range stays inside the word", words("1990–2000") == ["1990–2000"])
    // plain-text books (Project Gutenberg) type a dash as two hyphens
    check("two hyphens with no spaces round them divide two words, as an em dash does",
          words("Some years ago--never mind how long--having little money") ==
          ["Some", "years", "ago", "never", "mind", "how", "long", "having", "little", "money"]
          && words("wait--what? so---on") == ["wait", "what", "so", "on"],
          "\(words("Some years ago--never mind how long--having little money")) \(words("wait--what? so---on"))")
    check("…with a pause after the first of them", SpokenWords.tokens(in: "ago--never").map(\.pause) == [.clause, .none])
    check("a single hyphen stays in its word; hyphens that start or end a piece make no empty word",
          words("well-known and a-b-c") == ["well-known", "and", "a-b-c"]
          && words("--and then") == ["and", "then"] && words("---and") == ["and"] && words("wait--") == ["wait"]
          && words("a - b -- c") == ["a", "b", "c"])

    let sample = "Mr. Darcy bowed, but said nothing; then — slowly — he left. “Never!” she cried…"
    let tokens = SpokenWords.tokens(in: sample)
    let pauses = Dictionary(uniqueKeysWithValues: tokens.map { (String(sample[$0.range]), $0.pause) })
    check("a full stop after an abbreviation is not the end of a sentence", pauses["Mr"] == SpokenWords.Pause.none)
    check("a comma or semicolon is a short pause", pauses["bowed"] == .clause && pauses["nothing"] == .clause)
    check("a dash on its own lengthens the pause before it", pauses["then"] == .clause && pauses["slowly"] == .clause)
    check("a full stop, closing quote after ! and an ellipsis end a sentence", pauses["left"] == .sentence && pauses["Never"] == .sentence && pauses["cried"] == .sentence)
    check("plain words have no pause", pauses["Darcy"] == SpokenWords.Pause.none && pauses["but"] == SpokenWords.Pause.none)
    check("every range is inside the text and starts and ends on a letter or digit",
          tokens.allSatisfy { t in
              let word = sample[t.range]
              return !word.isEmpty && (word.first?.isLetter ?? false || word.first?.isNumber ?? false)
                  && (word.last?.isLetter ?? false || word.last?.isNumber ?? false)
          })

    let weight: (String) -> Double = { SpokenWords.tokens(in: $0).first?.weight ?? 0 }
    check("a longer word takes longer", weight("extraordinary") > weight("it") && weight("it") > 0)
    check("a number is spoken as many words", weight("1,200") > weight("an"))

    let chinese = "第一章灯光落在书页上"
    let pairs: (String) -> [Range<String.Index>] = { text in
        var out: [Range<String.Index>] = [], i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            out.append(i ..< j); i = j
        }
        return out
    }
    check("text with no spaces is split by the tokenizer given", words(chinese, split: pairs) == ["第一", "章灯", "光落", "在书", "页上"])
    check("…and is one piece without one", words(chinese) == [chinese])
    check("text with spaces ignores that tokenizer", words("two words", split: pairs) == ["two", "words"])

    section("Highlights: when each word is spoken")
    let text = "The old man, who had been sitting silent in the corner, rose slowly to his feet."
    let toks = SpokenWords.tokens(in: text)
    let timed = SpokenWords.schedule(toks, speech: 0.2 ... 5.2)
    check("every word has a time, in order", timed.count == toks.count && zip(timed, timed.dropFirst()).allSatisfy { $0.start < $1.start })
    check("the first word starts at the speech, a moment early", abs(timed[0].start - (0.2 - SpokenWords.lead)) < 1e-9, "\(timed[0].start)")
    check("the last word starts before the speech ends", timed.last!.start < 5.2 && timed.last!.start > 4.0)
    check("a comma pushes the next word later", {
        let plain = SpokenWords.schedule(SpokenWords.tokens(in: "alpha beta gamma"), speech: 0 ... 3)
        let comma = SpokenWords.schedule(SpokenWords.tokens(in: "alpha, beta gamma"), speech: 0 ... 3)
        return comma[1].start > plain[1].start
    }())
    check("a full stop pushes it later still", {
        let comma = SpokenWords.schedule(SpokenWords.tokens(in: "alpha, beta gamma"), speech: 0 ... 3)
        let stop = SpokenWords.schedule(SpokenWords.tokens(in: "alpha. beta gamma"), speech: 0 ... 3)
        return stop[1].start > comma[1].start
    }())
    check("the pause after the last word does not stretch the sentence", {
        let a = SpokenWords.schedule(SpokenWords.tokens(in: "one two three"), speech: 1 ... 4)
        let b = SpokenWords.schedule(SpokenWords.tokens(in: "one two three."), speech: 1 ... 4)
        return zip(a, b).allSatisfy { abs($0.start - $1.start) < 1e-9 }
    }())
    check("speech that starts at the very beginning never gives a negative time", SpokenWords.schedule(toks, speech: 0 ... 5).allSatisfy { $0.start >= 0 })
    check("one word is lit from the start", SpokenWords.schedule(SpokenWords.tokens(in: "Nobody."), speech: 0.1 ... 0.9).map(\.start) == [max(0.1 - SpokenWords.lead, 0)])
    check("no words, no times", SpokenWords.schedule([], speech: 0 ... 1).isEmpty)

    // a silence heard where the punctuation pauses pins the words after it to the sound —
    // with none heard the spread is the even one it always was
    let alphaToks = SpokenWords.tokens(in: "alpha, beta gamma")
    let noGap = SpokenWords.schedule(alphaToks, speech: 0 ... 3)
    let withGap = SpokenWords.schedule(alphaToks, speech: 0 ... 3, gaps: [1.0 ... 1.3])
    check("a silence where the comma is puts the word after it at its end",
          abs(withGap[1].start - (1.3 - SpokenWords.lead)) < 1e-9, "\(withGap[1].start)")
    check("…and moves nothing before it", abs(withGap[0].start - noGap[0].start) < 1e-9)
    check("a breath that lines up with no pause changes nothing", {
        let far = SpokenWords.schedule(alphaToks, speech: 0 ... 3, gaps: [2.0 ... 2.3])
        return zip(far, noGap).allSatisfy { abs($0.start - $1.start) < 1e-9 }
    }())
    check("a breath before the pause is stepped over, the pause still lands", {
        let breath = SpokenWords.schedule(alphaToks, speech: 0 ... 3, gaps: [0.3 ... 0.4, 1.0 ... 1.3])
        return abs(breath[1].start - withGap[1].start) < 1e-9
    }())
    check("silence where there is no pause to place stays unclaimed", {
        let plain = SpokenWords.tokens(in: "alpha beta gamma")
        let words = SpokenWords.schedule(plain, speech: 0 ... 3, gaps: [1.0 ... 1.3])
        return zip(words, SpokenWords.schedule(plain, speech: 0 ... 3)).allSatisfy { abs($0.start - $1.start) < 1e-9 }
    }())
    check("walking through the audio still visits every word once, in order", {
        var seen: [Int] = [], t = 0.0
        while t < 3.5 {
            if let i = SpokenWords.index(at: t, in: withGap), seen.last != i { seen.append(i) }
            t += 0.01
        }
        return seen == Array(0 ..< withGap.count)
    }())

    check("looking up the word at a time: the first before any has started", SpokenWords.index(at: 0, in: timed) == 0 && SpokenWords.index(at: -1, in: timed) == 0)
    check("…the last that has started", SpokenWords.index(at: timed[3].start, in: timed) == 3 && SpokenWords.index(at: timed[3].start + 0.001, in: timed) == 3
          && SpokenWords.index(at: timed[3].start - 0.001, in: timed) == 2)
    check("…the last word for ever after", SpokenWords.index(at: 99, in: timed) == timed.count - 1)
    check("…nothing when there are no words", SpokenWords.index(at: 1, in: []) == nil)
    check("walking through the audio visits every word once, in order", {
        var seen: [Int] = [], t = 0.0
        while t < 5.5 {
            if let i = SpokenWords.index(at: t, in: timed), seen.last != i { seen.append(i) }
            t += 0.01
        }
        return seen == Array(0 ..< timed.count)
    }())

    // Six sentences read by three Piper voices (Lessac, Amy, Alan): where the speech starts and ends in
    // the audio, and when an ASR heard each word begin (its timestamps lag the sound by about 0.33 s,
    // taken off here). The estimate is allowed to be about a tenth of a second off.
    struct Reference {
        var text: String
        var speech: ClosedRange<Double>
        var starts: [Double?]
    }
    let references: [Reference] = [
        Reference(text: "He opened the door quietly, looked up and down the corridor, and then stepped inside without a word.", speech: 0.08 ... 4.68, starts: [-0.12, 0.08, 0.32, 0.44, 0.80, 1.36, 1.60, 1.76, 1.88, 2.08, 2.20, 2.64, 2.84, 3.04, 3.60, 3.92, 4.24, 4.44]),
        Reference(text: "There was nothing to be done; we had lost the road, and night was coming on fast.", speech: 0.04 ... 3.95, starts: [-0.08, 0.12, 0.32, 0.56, 0.72, 0.84, 1.12, 1.28, 1.48, 1.72, 1.88, 2.20, 2.44, 2.68, 2.96, 3.32, 3.52]),
        Reference(text: "\"Well, Prince, so Genoa and Lucca are now just family estates of the Buonapartes,\" she said.", speech: 0.05 ... 6.26, starts: [0.11, 0.63, 1.23, 1.39, 1.87, 2.07, 2.51, 2.71, 3.03, 3.35, 3.79, 4.23, 4.35, nil, 5.63, 5.95]),
        Reference(text: "He opened the door quietly, looked up and down the corridor, and then stepped inside without a word.", speech: 0.06 ... 5.48, starts: [-0.05, 0.27, 0.55, 0.71, 1.07, 1.59, 1.91, 2.11, 2.31, 2.59, 2.83, 3.27, 3.51, 3.71, 4.11, 4.59, 4.95, 5.15]),
        Reference(text: "\"Well, Prince, so Genoa and Lucca are now just family estates of the Buonapartes,\" she said.", speech: 0.04 ... 6.08, starts: [0.27, 0.63, 1.23, 1.39, 1.87, 2.03, 2.51, 2.63, 2.91, 3.19, 3.79, 4.19, 4.31, nil, 5.47, 5.67]),
        Reference(text: "He opened the door quietly, looked up and down the corridor, and then stepped inside without a word.", speech: 0.05 ... 6.15, starts: [-0.05, 0.27, 0.59, 0.71, 1.07, 1.79, 2.11, 2.31, 2.51, 2.75, 2.95, 3.59, 3.87, 4.15, 4.75, 5.23, 5.63, 5.91]),
    ]
    var errors: [Double] = []
    var countsAgree = true
    for reference in references {
        let words = SpokenWords.schedule(SpokenWords.tokens(in: reference.text), speech: reference.speech)
        if words.count != reference.starts.count { countsAgree = false; continue }
        for (word, heard) in zip(words, reference.starts) { if let heard { errors.append(word.start - heard) } }
    }
    let meanError = errors.isEmpty ? .infinity : errors.map(abs).reduce(0, +) / Double(errors.count)
    let bias = errors.isEmpty ? .infinity : errors.reduce(0, +) / Double(errors.count)
    let within = errors.isEmpty ? 0 : Double(errors.filter { abs($0) < 0.25 }.count) / Double(errors.count)
    check("the reference sentences split into the words the recogniser heard", countsAgree && errors.count > 80, "\(errors.count) words")
    check("the estimate is within about a tenth of a second of when each word is spoken (\(Int(meanError * 1000)) ms)", meanError < 0.16, "\(meanError)")
    check("…and is not late or early overall (\(Int(bias * 1000)) ms)", abs(bias) < 0.1, "\(bias)")
    check("…and four words in five are within a quarter of a second (\(Int(within * 100))%)", within >= 0.8, "\(within)")

    section("Highlights: where the speech is in the audio")
    func tone(_ seconds: Double, rate: Double, amplitude: Float = 0.5) -> [Float] {
        (0 ..< Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / rate)) }
    }
    let rate = 16000.0
    let clip = [Float](repeating: 0, count: Int(0.3 * rate)) + tone(1.0, rate: rate) + [Float](repeating: 0, count: Int(0.2 * rate))
    let found = SpokenWords.speech(in: clip, sampleRate: rate)
    check("silence before and after is left out", abs(found.lowerBound - 0.3) < 0.03 && abs(found.upperBound - 1.3) < 0.03, "\(found)")
    check("a quiet tail is silence too", {
        let quiet = tone(0.5, rate: rate, amplitude: 0.5) + tone(0.5, rate: rate, amplitude: 0.002)
        let r = SpokenWords.speech(in: quiet, sampleRate: rate)
        return abs(r.upperBound - 0.5) < 0.03
    }())
    check("all silence is all of it", SpokenWords.speech(in: [Float](repeating: 0, count: 8000), sampleRate: rate) == 0 ... 0.5)
    check("a clip too short to measure is all of it", SpokenWords.speech(in: [0.1, 0.2], sampleRate: rate) == 0 ... 2 / rate)
    check("nothing is nothing", SpokenWords.speech(in: [], sampleRate: rate) == 0 ... 0)

    // the same measurement says where the voice paused inside the speech
    let paused = tone(0.5, rate: rate) + [Float](repeating: 0, count: Int(0.15 * rate)) + tone(0.5, rate: rate)
    let measured = SpokenWords.measure(in: paused, sampleRate: rate)
    check("a pause in the middle is heard as a gap", {
        guard measured.gaps.count == 1, let gap = measured.gaps.first else { return false }
        return abs(gap.lowerBound - 0.5) < 0.03 && abs(gap.upperBound - 0.65) < 0.03
    }(), "\(measured.gaps)")
    check("…and the bounds still reach both ends of the speech",
          abs(measured.bounds.lowerBound) < 0.03 && abs(measured.bounds.upperBound - 1.15) < 0.03, "\(measured.bounds)")
    check("a dip too short to be a pause is none", {
        let dip = tone(0.5, rate: rate) + [Float](repeating: 0, count: Int(0.04 * rate)) + tone(0.5, rate: rate)
        return SpokenWords.measure(in: dip, sampleRate: rate).gaps.isEmpty
    }())
    check("silence at the ends is the bounds', not a gap", {
        let edges = [Float](repeating: 0, count: Int(0.2 * rate)) + tone(0.6, rate: rate) + [Float](repeating: 0, count: Int(0.2 * rate))
        return SpokenWords.measure(in: edges, sampleRate: rate).gaps.isEmpty
    }())
    check("a sample rate that makes no sense is no speech, not a crash",
          SpokenWords.speech(in: [0.5, 0.5, 0.5, 0.5], sampleRate: 0) == 0 ... 0 && SpokenWords.speech(in: [0.5, 0.5, 0.5, 0.5], sampleRate: -1) == 0 ... 0
          && SpokenWords.speech(in: [0.5, 0.5, 0.5, 0.5], sampleRate: .nan) == 0 ... 0 && SpokenWords.speech(in: [0.5, 0.5, 0.5, 0.5], sampleRate: .infinity) == 0 ... 0)

    section("Highlights: the stored choices")
    check("sentence and word are on, line is off, until chosen", ReadAloudHighlights() == ReadAloudHighlights(sentence: true, line: false, word: true))
    let decoder = JSONDecoder()
    func decode(_ json: String) -> ReadAloudHighlights? { try? decoder.decode(ReadAloudHighlights.self, from: Data(json.utf8)) }
    check("settings saved before there were highlights read as the defaults", decode("{}") == ReadAloudHighlights())
    check("a key that is there is kept, the others default", decode(#"{"word":false}"#) == ReadAloudHighlights(sentence: true, line: false, word: false)
          && decode(#"{"line":true,"sentence":false}"#) == ReadAloudHighlights(sentence: false, line: true, word: true))
    check("they survive being saved", {
        let all = [ReadAloudHighlights(sentence: false, line: true, word: false), ReadAloudHighlights(sentence: true, line: true, word: true),
                   ReadAloudHighlights(sentence: false, line: false, word: false)]
        return all.allSatisfy { value in
            (try? JSONEncoder().encode(value)).flatMap { try? decoder.decode(ReadAloudHighlights.self, from: $0) } == value
        }
    }())
    check("line and word need the words; the sentence alone does not",
          ReadAloudHighlights(sentence: true, line: false, word: false).needsWords == false
          && ReadAloudHighlights(sentence: false, line: true, word: false).needsWords
          && ReadAloudHighlights(sentence: false, line: false, word: true).needsWords)
    check("all three off is off", ReadAloudHighlights(sentence: false, line: false, word: false).isOff && !ReadAloudHighlights().isOff)
}

@MainActor
func runPlayheadChecks() {
    section("Highlights: how far the voice has got")
    // two sentences queued one behind the other, in pieces of 250 frames (a quarter second at 1 kHz)
    let rate = 1000.0
    var clock = PlayheadClock()
    let a = clock.queue(frames: 1000), b = clock.queue(frames: 500)
    check("a sentence starts where the one before it ends", a == 0 && b == 1000)
    func at(_ start: Double, _ frames: Double) -> Double { clock.seconds(sentenceStart: start, frames: frames, sampleRate: rate) }
    check("nothing has played yet", at(a, 1000) == 0 && at(b, 500) == 0)

    clock.advance(seconds: 0.1, speed: 1, sampleRate: rate, pieceFrames: 250)
    check("time moves it on, at the voice's pace", abs(at(a, 1000) - 0.1) < 1e-9, "\(at(a, 1000))")
    clock.advance(seconds: 0.05, speed: 2, sampleRate: rate, pieceFrames: 250)
    check("twice as fast covers twice the audio", abs(at(a, 1000) - 0.2) < 1e-9, "\(at(a, 1000))")
    clock.advance(seconds: 5, speed: 1, sampleRate: rate, pieceFrames: 250)
    check("it cannot run past the piece being played", abs(at(a, 1000) - 0.25) < 1e-9, "\(at(a, 1000))")

    clock.finishedPiece(frames: 250)
    check("a piece heard in full puts it exactly there, and the next starts from its beginning", abs(at(a, 1000) - 0.25) < 1e-9)
    clock.advance(seconds: 0.05, speed: 1, sampleRate: rate, pieceFrames: 250)
    check("…and time goes on from it", abs(at(a, 1000) - 0.3) < 1e-9)
    for _ in 0 ..< 3 { clock.finishedPiece(frames: 250) }
    check("the first sentence is over; the second has not begun", at(a, 1000) == 1 && at(b, 500) == 0, "\(at(a, 1000)) \(at(b, 500))")
    clock.advance(seconds: 0.2, speed: 1, sampleRate: rate, pieceFrames: 250)
    check("then the second one moves", abs(at(b, 500) - 0.2) < 1e-9 && at(a, 1000) == 1)
    check("frames left count what has not played", clock.framesLeft(pending: 500) == 300 && clock.framesLeft(pending: 100) == 0)

    clock.restartPiece()
    check("after an interruption the piece starts again", at(b, 500) == 0)
    clock.reset()
    let c = clock.queue(frames: 200)
    check("starting over counts from nothing", c == 0 && at(c, 200) == 0 && clock.heard == 0)

    var junk = PlayheadClock()
    junk.advance(seconds: -1, speed: 1, sampleRate: 1000, pieceFrames: 100)
    junk.advance(seconds: 1, speed: 0, sampleRate: 1000, pieceFrames: 100)
    junk.advance(seconds: .nan, speed: 1, sampleRate: 1000, pieceFrames: 100)
    check("time going backwards, no speed or no time moves nothing", junk.into == 0 && junk.seconds(sentenceStart: 0, frames: 100, sampleRate: 0) == 0)
}
