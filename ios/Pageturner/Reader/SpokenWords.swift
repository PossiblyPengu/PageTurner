import Foundation

/// Where the words of a sentence fall in time, for a voice that says nothing about it: a neural voice
/// hands over one block of audio, where iOS's own voices call back for every word.
///
/// The estimate is the length of each word plus a pause where the punctuation asks for one, spread over
/// the part of the audio that is speech. Fitted against Piper voices reading 190 book sentences — with an
/// ASR's word timestamps as the reference — it is within a tenth of a second of the word for half the
/// words and within two tenths for 85%. Pure logic, so it is checked off-device (ios/Checks/bookmaster).
enum SpokenWords {
    /// A word to light: where it is in the sentence, and when it starts.
    struct Word: Equatable {
        /// The word without the punctuation around it.
        var range: Range<String.Index>
        /// Seconds into the audio at the voice's own pace — what the player reports.
        var start: TimeInterval
    }

    enum Pause: Int, Comparable {
        case none, clause, sentence

        static func < (a: Pause, b: Pause) -> Bool { a.rawValue < b.rawValue }
    }

    struct Token: Equatable {
        var range: Range<String.Index>
        /// How long the word takes, in units of one letter.
        var weight: Double
        /// What follows it.
        var pause: Pause
    }

    // MARK: Fitted numbers (units of one letter, which is about 45 ms)

    /// Every word takes this much besides its letters.
    static let wordBase = 1.2
    static let clausePause = 1.9
    static let sentencePause = 4.75
    /// A digit is spoken as several letters' worth ("1,200" is "one thousand two hundred").
    static let digitWeight = 3.0
    /// The highlight comes a little before the voice: that feels in step, a late one feels dragged.
    static let lead: TimeInterval = 0.05

    // MARK: Words

    /// The words of `text` — pieces between spaces, without the quotes and punctuation round them — and
    /// what each is followed by. Text with no spaces in it (Chinese, Japanese, Thai) is split by
    /// `split`, which the app backs with the system's word tokenizer.
    static func tokens(in text: String, split: ((String) -> [Range<String.Index>])? = nil) -> [Token] {
        let pieces: [Range<String.Index>]
        if let split, !text.contains(where: \.isWhitespace) {
            pieces = split(text)
        } else {
            pieces = spaced(text)
        }
        var found: [Token] = []
        for piece in pieces {
            let raw = text[piece]
            guard let first = raw.firstIndex(where: isWordCharacter),
                  let last = raw.lastIndex(where: isWordCharacter)
            else {
                // punctuation on its own ("—", "...") lengthens the pause after the word before it
                if let previous = found.indices.last {
                    found[previous].pause = max(found[previous].pause, pause(in: raw))
                }
                continue
            }
            let word = first ..< raw.index(after: last)
            var after = pause(in: raw[word.upperBound...])
            if after == .sentence, abbreviations.contains(raw[word].lowercased()) { after = .none }
            let weight = raw[word].reduce(0.0) { sum, character in
                character.isNumber ? sum + digitWeight : character.isLetter ? sum + 1 : sum
            }
            found.append(Token(range: word, weight: wordBase + weight, pause: after))
        }
        return found
    }

    /// Pieces of text between white space — and after a dash that joins two words ("ago—never", "ago--never"):
    /// the dash stays with the word before it, which is how the voice pauses there.
    private static func spaced(_ text: String) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if let from = start { pieces.append(from ..< index); start = nil }
            } else {
                let from = start ?? index
                start = from
                if index > from, let next = dashEnd(in: text, at: index) {
                    pieces.append(from ..< next)
                    start = nil
                    index = next
                    continue
                }
            }
            index = text.index(after: index)
        }
        if let from = start { pieces.append(from ..< text.endIndex) }
        return pieces
    }

    /// Em dashes (and the horizontal bar), which books set between words without spaces.
    private static let joiningDashes: Set<Character> = ["—", "―"]

    /// Where the dash at `index` ends, if it is one that follows a word and joins it to the next: an em
    /// dash, or two hyphens or more — plain-text books type a dash that way. One hyphen is part of the word.
    private static func dashEnd(in text: String, at index: String.Index) -> String.Index? {
        let character = text[index]
        let next = text.index(after: index)
        if joiningDashes.contains(character) { return next }
        // the first hyphen of a run that does not begin the piece
        guard character == "-", text[text.index(before: index)] != "-" else { return nil }
        var end = next
        while end < text.endIndex, text[end] == "-" { end = text.index(after: end) }
        return end > next ? end : nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Quotes and brackets that close a sentence without changing how it ends.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}"]
    private static let sentenceMarks: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "‼", "⁇", "⁈"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–", "-", "，", "；", "：", "、", "―"]
    /// A full stop after these is not the end of a sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "vs", "etc", "mt", "gen", "col", "capt", "lt", "sgt", "rev", "hon",
    ]

    private static func pause(in tail: Substring) -> Pause {
        guard let mark = tail.last(where: { !closers.contains($0) }) else { return .none }
        if sentenceMarks.contains(mark) { return .sentence }
        if clauseMarks.contains(mark) { return .clause }
        return .none
    }

    // MARK: Timing

    /// What `measure` hears in a sentence's audio: where the speech is, and the silences
    /// inside it — where the voice paused.
    struct Speech {
        var bounds: ClosedRange<TimeInterval>
        /// Quiet runs inside `bounds`, in the order they were heard.
        var gaps: [ClosedRange<TimeInterval>]
    }

    /// A silence expected by the punctuation is taken to be a heard one up to this far
    /// from where the word count alone would put it: further off, it is a breath.
    static let gapMatch: TimeInterval = 0.5

    /// When each word starts, spread over `speech` (the part of the audio that is not silence).
    /// A `gaps` silence that lines up with a pause the punctuation asked for pins it in
    /// place — the words around it land where the sound puts them, not at even weight. With
    /// none that match (or none heard) this is an even spread, as it has always been.
    static func schedule(_ tokens: [Token], speech: ClosedRange<TimeInterval>, gaps: [ClosedRange<TimeInterval>] = []) -> [Word] {
        guard !tokens.isEmpty else { return [] }
        var offsets: [Double] = []
        var total = 0.0
        for (i, token) in tokens.enumerated() {
            offsets.append(total)
            total += token.weight
            if i < tokens.count - 1 {
                switch token.pause {
                case .none: break
                case .clause: total += clausePause
                case .sentence: total += sentencePause
                }
            }
        }
        let span = speech.upperBound - speech.lowerBound
        guard total > 0 else { return tokens.map { Word(range: $0.range, start: max(speech.lowerBound - lead, 0)) } }

        // word-weight → seconds. The ends are always known; each pause matched to a heard
        // silence pins its two edges to the silence's, and between anchors the spread is
        // even as before — so a comma's pause moves the words after it, and only them.
        var anchors: [(weight: Double, time: TimeInterval)] = [(0, speech.lowerBound)]
        var g = 0
        for i in 0 ..< tokens.count - 1 where tokens[i].pause != .none && g < gaps.count {
            let pauseWeight = tokens[i].pause == .sentence ? sentencePause : clausePause
            let before = offsets[i] + tokens[i].weight
            let expected = speech.lowerBound + span * (before + pauseWeight / 2) / total
            while g < gaps.count, gaps[g].center < expected - gapMatch { g += 1 }
            guard g < gaps.count, abs(gaps[g].center - expected) <= gapMatch else { continue }
            anchors.append((before, gaps[g].lowerBound))
            anchors.append((before + pauseWeight, gaps[g].upperBound))
            g += 1
        }
        anchors.append((total, speech.upperBound))

        return tokens.indices.map { i in
            Word(range: tokens[i].range, start: max(Self.seconds(at: offsets[i], through: anchors) - lead, 0))
        }
    }

    /// Where a word-weight lands between its anchors.
    private static func seconds(at weight: Double, through anchors: [(weight: Double, time: TimeInterval)]) -> TimeInterval {
        var low = 0, high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid].weight <= weight { low = mid } else { high = mid - 1 }
        }
        let a = anchors[low]
        guard low + 1 < anchors.count else { return a.time }
        let b = anchors[low + 1]
        return a.time + (b.time - a.time) * (weight - a.weight) / (b.weight - a.weight)
    }

    /// The word being said `time` seconds in: the last that has started — the first until any has.
    static func index(at time: TimeInterval, in words: [Word]) -> Int? {
        guard !words.isEmpty else { return nil }
        var low = 0, high = words.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if words[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The stretch of `samples` that is speech: from the first to the last 10 ms that is louder than
    /// 2% of the loud parts. Voices start and end with a little silence.
    static func speech(in samples: [Float], sampleRate: Double) -> ClosedRange<TimeInterval> {
        guard let parts = levels(in: samples, sampleRate: sampleRate) else { return 0 ... 0 }
        guard let first = parts.levels.firstIndex(where: { $0 > parts.threshold }),
              let last = parts.levels.lastIndex(where: { $0 > parts.threshold })
        else { return 0 ... parts.duration }
        let from = Double(first) * parts.seconds
        return from ... max(min(Double(last + 1) * parts.seconds, parts.duration), from)
    }

    /// The stretch of `samples` that is speech and the silences inside it: bounds as
    /// `speech(in:)`; a gap is a quiet run long enough to be a pause the voice meant (~0.09 s),
    /// strictly inside the bounds — the outer silence is what the bounds themselves trim.
    /// `schedule` anchors its pauses to these.
    static func measure(in samples: [Float], sampleRate: Double) -> Speech {
        guard let parts = levels(in: samples, sampleRate: sampleRate) else { return Speech(bounds: 0 ... 0, gaps: []) }
        guard let first = parts.levels.firstIndex(where: { $0 > parts.threshold }),
              let last = parts.levels.lastIndex(where: { $0 > parts.threshold })
        else { return Speech(bounds: 0 ... parts.duration, gaps: []) }
        let from = Double(first) * parts.seconds
        let bounds = from ... max(min(Double(last + 1) * parts.seconds, parts.duration), from)
        // `first`/`last` are loud by construction, so a quiet run can never reach either end
        let minRun = max(Int((0.09 / parts.seconds).rounded()), 1)
        var gaps: [ClosedRange<TimeInterval>] = []
        var quiet: Int?
        for w in first ... last {
            if parts.levels[w] <= parts.threshold {
                quiet = quiet ?? w
            } else {
                if let at = quiet, w - at >= minRun {
                    gaps.append(Double(at) * parts.seconds ... Double(w) * parts.seconds)
                }
                quiet = nil
            }
        }
        return Speech(bounds: bounds, gaps: gaps)
    }

    /// Loudness per 10 ms of `samples`, the level a window must top to count as speech
    /// (2% of the loud parts), the width of a window in seconds and the clip's length.
    /// `levels` empty means there was nothing to measure against — too short or all quiet —
    /// and the whole clip counts as speech. nil is a sample rate that makes no sense.
    private static func levels(
        in samples: [Float], sampleRate: Double
    ) -> (levels: [Float], threshold: Float, seconds: TimeInterval, duration: TimeInterval)? {
        guard sampleRate > 0, sampleRate.isFinite else { return nil }
        let duration = Double(samples.count) / sampleRate
        let window = max(Int(sampleRate * 0.01), 1)
        let count = samples.count / window
        guard count >= 3 else { return ([], 0, 0, duration) }
        var level = [Float](repeating: 0, count: count)
        for w in 0 ..< count {
            var sum: Float = 0
            for i in (w * window) ..< ((w + 1) * window) { sum += samples[i] * samples[i] }
            level[w] = (sum / Float(window)).squareRoot()
        }
        let reference = level.sorted()[Int(Double(count - 1) * 0.95)]
        guard reference > 1e-4 else { return ([], 0, 0, duration) }
        return (level, reference * 0.02, Double(window) / sampleRate, duration)
    }
}

private extension ClosedRange where Bound == TimeInterval {
    var center: TimeInterval { (lowerBound + upperBound) / 2 }
}
