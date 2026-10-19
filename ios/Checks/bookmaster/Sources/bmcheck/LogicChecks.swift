import Foundation

// Checks for the app's pure logic: audiobook chapters, the BookMaster resume
// offer and the notification plan. No servers needed.

private func chapter(_ id: Int, _ title: String, _ start: Double, _ end: Double) -> AudioChapter {
    AudioChapter(id: id, title: title, start: start, end: end)
}

@MainActor
func runLogic() {
    section("Audiobook chapters")
    // a multi-file book: one chapter per file
    let tracks = AudioChapters.fromTracks(titles: ["Intro", "One", "Two"], offsets: [0, 120, 600], duration: 1_500)
    check("a chapter per file", tracks.count == 3, "\(tracks.count)")
    check("tracks start where the files do", tracks.map(\.start) == [0, 120, 600], "\(tracks.map(\.start))")
    check("each runs to the next, the last to the end", tracks.map(\.end) == [120, 600, 1_500], "\(tracks.map(\.end))")
    check("titles kept", tracks.map(\.title) == ["Intro", "One", "Two"])
    check("ids are the positions", tracks.map(\.id) == [0, 1, 2])

    // an m4b's markers arrive in any order, with gaps in the data
    let raw: [(title: String, start: TimeInterval, end: TimeInterval?)] = [
        ("Two", 600, 900), ("", 120, nil), ("Intro", 0, 120), ("Dup of one", 120.2, nil), ("Past the end", 5_000, nil),
        ("Negative", -4, nil),
    ]
    let marked = AudioChapters.normalise(raw, duration: 1_000)
    check("sorted by start", marked.map(\.start) == [0, 120, 600], "\(marked.map(\.start))")
    check("a marker on the same instant is dropped (first one wins)", marked.count == 3, "\(marked.count)")
    check("an untitled marker is 'Chapter N'", marked[1].title == "Chapter 2", marked[1].title)
    check("a marker past the end is dropped", !marked.contains { $0.start >= 1_000 })
    check("a marker before the start is dropped", !marked.contains { $0.start < 0 })
    check("the last chapter runs to its own end, clamped to the book", marked.last?.end == 900, "\(String(describing: marked.last?.end))")
    check("a chapter runs to the next one's start", marked[0].end == 120 && marked[1].end == 600, "\(marked.map(\.end))")
    check("a marker with no end runs to the book's end", AudioChapters.normalise([("Only", 0, nil)], duration: 300).first?.end == 300)
    check("an end past the book is clamped", AudioChapters.normalise([("A", 0, 9_999)], duration: 300).first?.end == 300)
    check("no markers, no chapters", AudioChapters.normalise([], duration: 300).isEmpty)
    check("nothing is made of an unknown duration", AudioChapters.normalise([("A", 0, nil)], duration: 0).isEmpty)
    check("lengths", tracks.map(\.length) == [120, 480, 900], "\(tracks.map(\.length))")

    let list = tracks
    check("index: the very start", AudioChapters.index(at: 0, in: list) == 0)
    check("index: inside the first", AudioChapters.index(at: 119.9, in: list) == 0)
    check("index: exactly on a boundary belongs to the chapter that starts there", AudioChapters.index(at: 120, in: list) == 1)
    check("index: inside the last", AudioChapters.index(at: 1_499, in: list) == 2)
    check("index: past the end is the last", AudioChapters.index(at: 99_999, in: list) == 2)
    check("index: before the first is the first", AudioChapters.index(at: -5, in: list) == 0)
    check("index: none without chapters", AudioChapters.index(at: 10, in: []) == nil)
    let many = (0..<400).map { chapter($0, "c\($0)", Double($0) * 60, Double($0 + 1) * 60) }
    check("index: binary search over 400 chapters", (0..<400).allSatisfy { AudioChapters.index(at: Double($0) * 60 + 30, in: many) == $0 })

    // a position that was sought to lands a hair before the chapter that was asked for
    check("index: a position a hair before a chapter's start is at its start (seek quantises to 1/600 s)", AudioChapters.index(at: 120 - 1.0 / 600, in: list) == 1)
    check("index: but not a second before it", AudioChapters.index(at: 119, in: list) == 0)

    // audio before the first marker is its own chapter
    let leadIn = AudioChapters.normalise([("One", 6, 100), ("", 100, nil), ("Three", 200, 300)], duration: 300)
    check("a lead-in before the first marker is a chapter of its own", leadIn.first?.title == "Opening" && leadIn.first?.start == 0 && leadIn.first?.end == 6, "\(leadIn.map(\.title)) \(leadIn.map(\.start))")
    check("…so every marker's chapter is still there", leadIn.map(\.title) == ["Opening", "One", "Chapter 2", "Three"], "\(leadIn.map(\.title))")
    check("…and the lead-in chapter runs up to the first marker, no gaps", zip(leadIn, leadIn.dropFirst()).allSatisfy { $0.end == $1.start })
    check("from the lead-in, next goes to chapter one and previous stays", AudioChapters.index(at: 2, in: leadIn) == 0 && AudioChapters.previousTarget(position: 2, in: leadIn) == 0)
    check("a first marker under a second in is not a lead-in", AudioChapters.normalise([("One", 0.4, 100)], duration: 100).map(\.title) == ["One"])
    check("a first marker at 0 is not either", AudioChapters.normalise([("One", 0, 100)], duration: 100).map(\.title) == ["One"])

    // which file holds a time
    let offsets: [TimeInterval] = [0, 120, 600]
    check("track: inside each file", AudioChapters.trackIndex(at: 50, offsets: offsets) == 0 && AudioChapters.trackIndex(at: 130, offsets: offsets) == 1 && AudioChapters.trackIndex(at: 700, offsets: offsets) == 2)
    check("track: on a boundary belongs to the file that starts there", AudioChapters.trackIndex(at: 120, offsets: offsets) == 1)
    check("track: the very end of the book is the last file", AudioChapters.trackIndex(at: 1_500, offsets: offsets) == 2)
    check("track: a hair before a file is that file (quantised seek)", AudioChapters.trackIndex(at: 120 - 1.0 / 600, offsets: offsets) == 1)
    check("track: none without files", AudioChapters.trackIndex(at: 5, offsets: []) == nil)

    check("previous: well into a chapter restarts it", AudioChapters.previousTarget(position: 400, in: list) == 1)
    check("previous: at its head goes back one", AudioChapters.previousTarget(position: 121, in: list) == 0)
    check("previous: at the head of the first stays", AudioChapters.previousTarget(position: 1, in: list) == 0)
    check("previous: none without chapters", AudioChapters.previousTarget(position: 1, in: []) == nil)

    section("BookMaster resume offer")
    func book(progression: Double?, remote: Double?, status: String? = "reading", dismissed: Date? = nil) -> Book {
        var b = Book(id: UUID(), title: "Dune", author: "Frank Herbert", fileName: "x.epub", fileNames: ["x.epub"], addedAt: Date())
        b.progression = progression
        b.bmRemotePercent = remote
        b.bmStatus = status
        b.resumeDismissedAt = dismissed
        return b
    }
    check("offered when BookMaster is well ahead", ResumeOffer.target(for: book(progression: 0.18, remote: 62)) == 0.62)
    check("offered for a book never opened here", ResumeOffer.target(for: book(progression: nil, remote: 40)) == 0.4)
    check("not offered when this device is ahead", ResumeOffer.target(for: book(progression: 0.7, remote: 62)) == nil)
    check("not offered when level", ResumeOffer.target(for: book(progression: 0.62, remote: 62)) == nil)
    check("not offered for a trivial lead (under 2 points)", ResumeOffer.target(for: book(progression: 0.60, remote: 61)) == nil)
    check("offered at exactly the margin", ResumeOffer.target(for: book(progression: 0.60, remote: 62)) == 0.62)
    check("not offered with no remote position", ResumeOffer.target(for: book(progression: 0.1, remote: nil)) == nil)
    check("not offered for a zero remote position", ResumeOffer.target(for: book(progression: nil, remote: 0)) == nil)
    check("not offered once finished on BookMaster", ResumeOffer.target(for: book(progression: 0.1, remote: 100, status: "read")) == nil)
    check("not offered when given up on", ResumeOffer.target(for: book(progression: 0.1, remote: 50, status: "dnf")) == nil)
    check("not offered when abandoned on BookMaster", ResumeOffer.target(for: book(progression: 0.1, remote: 50, status: "abandoned")) == nil)
    check("not offered when BookMaster says it is all the way through", ResumeOffer.target(for: book(progression: 0.1, remote: 99.5)) == nil)
    check("want-to-read with a position still offers", ResumeOffer.target(for: book(progression: 0.1, remote: 30, status: "want_to_read")) == 0.3)
    check("a non-finite remote value is ignored", ResumeOffer.target(for: book(progression: 0.1, remote: .infinity)) == nil)

    let now = Date()
    check("a declined offer is quiet for a day",
          ResumeOffer.target(for: book(progression: 0.1, remote: 60, dismissed: now.addingTimeInterval(-3_600)), now: now) == nil)
    check("then it asks again",
          ResumeOffer.target(for: book(progression: 0.1, remote: 60, dismissed: now.addingTimeInterval(-90_000)), now: now) == 0.6)

    var jumped = book(progression: 0.18, remote: 62, dismissed: now)
    jumped.locatorJSON = "{\"href\":\"ch3.xhtml\"}"
    jumped.audioPosition = 1_234
    ResumeOffer.accept(&jumped, fraction: 0.62)
    check("accepting moves the book to BookMaster's place", jumped.progression == 0.62)
    check("accepting drops the saved locator and audio second", jumped.locatorJSON == nil && jumped.audioPosition == nil)
    check("accepting clears the decline", jumped.resumeDismissedAt == nil)

    section("BookMaster page count")
    var paged = book(progression: 0.1, remote: nil)
    paged.pages = 300
    let pagedRef = String(data: try! JSONEncoder().encode(paged.bookMasterRef), encoding: .utf8)!
    check("a known page count rides the push as total_pages",
          pagedRef.contains("\"total_pages\":300"), pagedRef)
    let pagelessRef = String(data: try! JSONEncoder().encode(book(progression: 0.1, remote: nil).bookMasterRef), encoding: .utf8)!
    check("no count means no field — the percent alone answers there",
          !pagelessRef.contains("total_pages"))
    var clamped = book(progression: 0.1, remote: 60)
    ResumeOffer.accept(&clamped, fraction: 7)
    check("an out-of-range jump is clamped", clamped.progression == 1)
    var turned = book(progression: 0.18, remote: 62)
    turned.locatorJSON = "{\"href\":\"ch3.xhtml\"}"
    ResumeOffer.decline(&turned, now: now)
    check("declining keeps the place and notes the time", turned.progression == 0.18 && turned.locatorJSON != nil && turned.resumeDismissedAt == now)
    check("labels round", ResumeOffer.label(0.625) == "63%" || ResumeOffer.label(0.625) == "62%")
    check("label of a whole number", ResumeOffer.label(0.62) == "62%")

    section("Notification plan")
    func nudge(_ id: String, from: String = "Kristen", title: String = "Hyperion", author: String? = "Dan Simmons", note: String? = nil) -> BMNudge {
        BMNudge(id: id, note: note, fromName: from, title: title, author: author)
    }
    let first = NotificationPlan.plan(nudges: [nudge("a")], notices: [], seen: nil)
    check("the first look announces nothing", first.items.isEmpty)
    check("…but remembers what is waiting", first.seen == ["nudge:a"], "\(first.seen)")

    let quiet = NotificationPlan.plan(nudges: [nudge("a")], notices: [], seen: first.seen)
    check("nothing new, nothing said", quiet.items.isEmpty)

    let fresh = NotificationPlan.plan(nudges: [nudge("a"), nudge("b", note: "you will love this")], notices: [], seen: first.seen)
    check("a new suggestion is announced once", fresh.items.count == 1 && fresh.items[0].id == "nudge:b", "\(fresh.items)")
    check("who it is from", fresh.items.first?.title == "Kristen suggested a book", fresh.items.first?.title ?? "nil")
    check("what it says", fresh.items.first?.body == "Hyperion by Dan Simmons — “you will love this”", fresh.items.first?.body ?? "nil")
    check("then both are remembered", fresh.seen == ["nudge:a", "nudge:b"])

    let bare = NotificationPlan.plan(nudges: [nudge("c", from: "", title: "Solaris", author: nil)], notices: [], seen: [])
    check("no sender, no author, no note", bare.items.first?.title == "A book suggestion" && bare.items.first?.body == "Solaris", "\(bare.items)")

    let answered = NotificationPlan.plan(nudges: [], notices: [], seen: ["nudge:a", "nudge:b"])
    check("an answered suggestion drops out of the remembered set", answered.seen.isEmpty, "\(answered.seen)")

    let notices = [
        BMNotice(id: "n1", app: "quest-log", text: "Your streak is at risk"),
        BMNotice(id: "n2", app: "kindred", text: "A new entry"),
    ]
    let noticed = NotificationPlan.plan(nudges: [], notices: notices, seen: ["notice:n1"])
    check("a new notice from another app is announced", noticed.items.count == 1 && noticed.items[0].title == "Kindred" && noticed.items[0].body == "A new entry", "\(noticed.items)")
    check("app names", NotificationPlan.appName("quest-log") == "Quest Log" && NotificationPlan.appName("bookmaster") == "BookMaster"
          && NotificationPlan.appName("") == "BookMaster" && NotificationPlan.appName("some-new_app") == "Some New App")

    let pile = NotificationPlan.plan(nudges: (1...5).map { nudge("p\($0)") }, notices: [], seen: [])
    check("a pile of new things becomes one notification", pile.items.count == 1 && pile.items[0].title == "5 new things on BookMaster", "\(pile.items)")
    check("…and all of them are remembered", pile.seen.count == 5)
    let three = NotificationPlan.plan(nudges: (1...3).map { nudge("q\($0)") }, notices: [], seen: [])
    check("three is still three", three.items.count == 3)

    section("Back history after a jump")
    func spot(_ href: String, _ p: Double) -> JumpHistory.Spot { .init(locatorJSON: "{\"href\":\"\(href)\"}", href: href, progression: p) }
    var h = JumpHistory()
    check("nothing to go back to at first", h.back == nil)
    check("a jump far away is remembered", h.record(origin: spot("ch1.xhtml", 0.10), landed: spot("notes.xhtml", 0.95)))
    check("…and Back returns to where you were", h.back == spot("ch1.xhtml", 0.10))
    check("a hop inside one file under 1% is not", !JumpHistory().recordedCopy(origin: spot("a", 0.500), landed: spot("a", 0.505)))
    check("a hop to another file is, however short", JumpHistory().recordedCopy(origin: spot("a", 0.500), landed: spot("b", 0.502)))
    check("going back pops it", h.goBack() == spot("ch1.xhtml", 0.10) && h.back == nil)
    check("going back with nothing there is nil", h.goBack() == nil)

    var g = JumpHistory()
    g.record(origin: spot("a", 0.10), landed: spot("b", 0.90))
    g.readOn(to: 0.90)   // the landing
    g.readOn(to: 0.93)
    check("reading a little past the landing keeps the way back", g.back != nil)
    g.readOn(to: 0.985)
    check("reading well past it (over 8%) drops the way back", g.back == nil)
    var g2 = JumpHistory()
    g2.record(origin: spot("a", 0.50), landed: spot("b", 0.10))
    g2.readOn(to: 0.10)
    g2.readOn(to: 0.01)
    check("reading backwards past it counts too", g2.back == nil)
    var g3 = JumpHistory()
    g3.record(origin: spot("a", 0.10), landed: spot("b", 0.90))
    g3.readOn(to: 0.90)
    g3.record(origin: spot("b", 0.90), landed: spot("c", 0.30))
    check("two jumps stack: Back goes to the newest origin first", g3.back == spot("b", 0.90))
    check("…then the one before", { _ = g3.goBack(); return g3.back == spot("a", 0.10) }())
    var g4 = JumpHistory()
    g4.record(origin: spot("a", 0.10), landed: spot("b", 0.90))
    check("jumping again from near the same origin does not stack a duplicate", !g4.record(origin: spot("a", 0.105), landed: spot("c", 0.60)) && g4.entries.count == 1)
    var g5 = JumpHistory()
    for i in 0..<40 { g5.record(origin: spot("f\(i)", Double(i) / 100), landed: spot("z", 0.99)) }
    check("the history is capped", g5.entries.count == JumpHistory.capacity, "\(g5.entries.count)")
    check("…keeping the newest", g5.back == spot("f39", 0.39))
    g5.clear()
    check("clear forgets everything", g5.back == nil)

    section("Highlight export")
    func hl(_ text: String, _ p: Double?, note: String? = nil, chapter: String? = nil, at: Double = 0) -> Highlight {
        Highlight(locatorJSON: "{}", text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + at),
                  color: nil, note: note, chapter: chapter, progression: p)
    }
    let md = HighlightExport.markdown(title: "Dune", author: "Frank Herbert", highlights: [
        hl("Second", 0.50, note: "remember this", chapter: "Book Two"),
        hl("First\nacross two lines", 0.10, chapter: "Book One"),
        hl("   ", nil),
        hl("No place, older", nil, at: 1),
        hl("No place, newer", nil, at: 2),
    ])
    check("title and author lead", md.hasPrefix("# Dune\n\n*Frank Herbert*\n"), String(md.prefix(40)))
    check("reading order, not creation order", (md.range(of: "First")?.lowerBound ?? md.endIndex) < (md.range(of: "Second")?.lowerBound ?? md.startIndex))
    check("ones with no place go last, oldest first", (md.range(of: "No place, older")?.lowerBound ?? md.startIndex) < (md.range(of: "No place, newer")?.lowerBound ?? md.startIndex)
          && (md.range(of: "Second")?.lowerBound ?? md.endIndex) < (md.range(of: "No place, older")?.lowerBound ?? md.startIndex))
    check("a blank highlight is skipped", !md.contains(">    "))
    check("a multi-line passage is one quote block", md.contains("> First\n> across two lines"))
    check("a note is included", md.contains("**Note:** remember this"))
    check("chapter and percent", md.contains("*Book One · 10%*") && md.contains("*Book Two · 50%*"), md)
    check("it ends with a newline", md.hasSuffix("\n"))
    check("no author, no author line", !HighlightExport.markdown(title: "T", author: "", highlights: []).contains("**"))
    check("a note on a highlight with no text still exports", HighlightExport.markdown(title: "T", author: "", highlights: [hl("", 0.2, note: "just a note")]).contains("**Note:** just a note"))
    check("file name", HighlightExport.fileName(for: "Dune") == "Dune – Highlights.md")
    check("file name drops what a file system dislikes", HighlightExport.fileName(for: "A/B: C?") == "A B C – Highlights.md", HighlightExport.fileName(for: "A/B: C?"))
    check("file name for an empty title", HighlightExport.fileName(for: "  ") == "Book – Highlights.md")
    check("colours: unknown falls back to yellow", HighlightColor(saved: "mauve") == .yellow && HighlightColor(saved: nil) == .yellow)
    check("colours: saved ones come back", HighlightColor(saved: "pink") == .pink && HighlightColor.allCases.count == 5)

    section("Dates on bookmarks and highlights")
    let nowDate = Date()
    var book = Book(id: UUID(), title: "T", author: "A", fileName: "x.epub", fileNames: ["x.epub"], addedAt: nowDate)
    let made = Date(timeIntervalSince1970: nowDate.timeIntervalSince1970 - 86_400 * 3)
    book.highlights = [Highlight(locatorJSON: "{}", text: "x", createdAt: made)]
    book.bookmarks = [Bookmark(title: "b", locatorJSON: "{}", progression: 0.2, createdAt: made)]
    // what the app does: write seconds since 1970, read with the default decoder — repeatedly
    func cycle(_ b: Book) -> Book {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let data = try! enc.encode([b])
        return try! JSONDecoder().decode([Book].self, from: data)[0]
    }
    var cycled = book
    for _ in 0..<4 { cycled = cycle(cycled) }
    check("a highlight's date survives four save/load cycles", abs(cycled.highlights[0].createdAt.timeIntervalSince(made)) < 2, "\(cycled.highlights[0].createdAt)")
    check("so does a bookmark's", abs(cycled.bookmarks[0].createdAt.timeIntervalSince(made)) < 2, "\(cycled.bookmarks[0].createdAt)")
    check("new highlight fields survive", {
        var b = book
        b.highlights[0].color = "green"; b.highlights[0].note = "n"; b.highlights[0].chapter = "C"; b.highlights[0].progression = 0.4
        let r = cycle(b).highlights[0]
        return r.color == "green" && r.note == "n" && r.chapter == "C" && r.progression == 0.4
    }())
    // a drifted date (each mismatched save moved it a whole 31-year gap on) is walked back
    let drifted = made.timeIntervalSince1970 + 978_307_200 * 2
    check("a date drifted forward by two gaps is walked back", abs((StoredDate.read(drifted)?.timeIntervalSince(made)) ?? 9e9) < 2)
    check("a date from an early build (2001-based) is read right", abs((StoredDate.read(made.timeIntervalSinceReferenceDate)?.timeIntervalSince(made)) ?? 9e9) < 2)
    check("the web's milliseconds are read right", abs((StoredDate.read(made.timeIntervalSince1970 * 1000)?.timeIntervalSince(made)) ?? 9e9) < 2)
    check("zero and junk are no date", StoredDate.read(0) == nil && StoredDate.read(-5) == nil && StoredDate.read(.nan) == nil && StoredDate.read(nil) == nil)
    let old = #"[{"id":"\#(UUID().uuidString)","title":"T","author":"A","fileName":"x.epub","addedAt":\#(nowDate.timeIntervalSinceReferenceDate),"highlights":[{"id":"\#(UUID().uuidString)","locatorJSON":"{}","text":"old","createdAt":\#(made.timeIntervalSinceReferenceDate)}]}]"#
    let legacy = try? JSONDecoder().decode([Book].self, from: Data(old.utf8))
    check("a highlight from before colours decodes (no colour, no note)", legacy?.first?.highlights.first?.color == nil && legacy?.first?.highlights.first?.note == nil && legacy?.first?.highlights.first?.text == "old")
    check("…with its early-build date repaired", abs((legacy?.first?.highlights.first?.createdAt.timeIntervalSince(made)) ?? 9e9) < 2)
    check("…and was never sent to BookMaster as a quote", legacy?.first?.highlights.first?.quoted == nil)
    var sentOne = Highlight(locatorJSON: "{}", text: "a line")
    sentOne.quoted = true
    let sentRound = try? JSONDecoder().decode([Highlight].self, from: JSONEncoder().encode([sentOne]))
    check("a saved word is the selection without its edge punctuation",
          SavedWord.clean("  “Sullen,” ") == "Sullen" && SavedWord.clean("\n ephemeral \n") == "ephemeral"
          && SavedWord.clean("don’t") == "don’t" && SavedWord.clean("well-known") == "well-known")
    check("…or a short phrase, but never a sentence or nothing",
          SavedWord.clean("a b c d") == "a b c d" && SavedWord.clean("one two three four five") == nil
          && SavedWord.clean("") == nil && SavedWord.clean(" “ ” ") == nil && SavedWord.clean(String(repeating: "x", count: 60)) == nil)
    check("the line around a word is kept whole",
          SavedWord.context(before: "The weather had turned ", word: "sullen", after: " and grey.") == "The weather had turned sullen and grey.")
    check("…nothing around it, nothing kept", SavedWord.context(before: nil, word: "sullen", after: nil) == nil
          && SavedWord.context(before: " ", word: "sullen", after: "\n") == nil)
    let long = String(repeating: "lorem ipsum ", count: 20) + "the weather had turned "
    let cut = SavedWord.context(before: long, word: "sullen", after: " and grey and cold and wet and windy for days on end without a break in it", reach: 20)
    check("…cut on word edges, with an ellipsis where it was cut", cut == "…weather had turned sullen and grey and cold…", cut ?? "nil")
    check("a quote mark stays against the word it opens", SavedWord.context(before: "He said “", word: "sullen", after: "” and left.") == "He said “sullen” and left.")
    var withWords = Book(id: UUID(), title: "T", author: "A", fileName: "x.epub", fileNames: ["x.epub"], addedAt: Date())
    withWords.words = [SavedWord(word: "sullen", context: "turned sullen and grey", chapter: "One")]
    let wordsRound = try? JSONDecoder().decode(Book.self, from: JSONEncoder().encode(withWords))
    check("saved words survive the library file, and an older book has none",
          wordsRound?.words.first?.word == "sullen" && wordsRound?.words.first?.context == "turned sullen and grey"
          && (try? JSONDecoder().decode([Book].self, from: Data(old.utf8)))?.first?.words.isEmpty == true)
    check("a highlight remembers it was sent as a quote", sentRound?.first?.quoted == true && Highlight(locatorJSON: "{}", text: "x").quoted == nil)
}


@MainActor
func runStatsChecks() {
    section("Local reading stats")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    // Wed 14 Feb 2024, 15:00 UTC
    let now = Date(timeIntervalSince1970: 1_707_922_800)
    func at(daysAgo: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
    let bookA = UUID(), bookB = UUID()
    func session(_ book: UUID, _ title: String, daysAgo: Int, minutes: Double, hour: Int = 12, audio: Bool = false) -> ReadingSession {
        ReadingSession(bookID: book, title: title, end: at(daysAgo: daysAgo, hour: hour), minutes: minutes, progressStart: 0, progressEnd: 0.1, audio: audio)
    }
    func stats(_ s: [ReadingSession], days: Int = 14) -> ReadingStats { ReadingStats.compute(s, now: now, calendar: cal, days: days) }

    let empty = stats([])
    check("no sessions: zeros", empty.minutesToday == 0 && empty.minutesTotal == 0 && empty.currentStreak == 0 && empty.longestStreak == 0 && empty.perBook.isEmpty)
    check("the chart always has the asked-for number of days, today last", empty.daily.count == 14 && empty.daily.last?.date == cal.startOfDay(for: now) && empty.daily.first?.date == at(daysAgo: 13, hour: 0))
    check("days are consecutive, oldest first", zip(empty.daily, empty.daily.dropFirst()).allSatisfy { cal.date(byAdding: .day, value: 1, to: $0.date) == $1.date })

    let one = stats([session(bookA, "Dune", daysAgo: 0, minutes: 30)])
    check("today's minutes", one.minutesToday == 30 && one.minutesLast7Days == 30 && one.minutesTotal == 30 && one.sessionCount == 1)
    check("a day of reading is a one-day streak", one.currentStreak == 1 && one.longestStreak == 1)
    check("today's bar is the last one", one.daily.last?.minutes == 30 && one.daily.dropLast().allSatisfy { $0.minutes == 0 })

    let alive = stats([session(bookA, "Dune", daysAgo: 1, minutes: 20), session(bookA, "Dune", daysAgo: 2, minutes: 20), session(bookA, "Dune", daysAgo: 3, minutes: 20)])
    check("a streak stays alive until today is over (nothing yet today)", alive.currentStreak == 3 && alive.minutesToday == 0, "\(alive.currentStreak)")
    let broken = stats([session(bookA, "Dune", daysAgo: 2, minutes: 20), session(bookA, "Dune", daysAgo: 3, minutes: 20)])
    check("…but not past a missed day", broken.currentStreak == 0 && broken.longestStreak == 2, "\(broken.currentStreak)/\(broken.longestStreak)")
    let gap = stats([session(bookA, "Dune", daysAgo: 0, minutes: 5), session(bookA, "Dune", daysAgo: 2, minutes: 5), session(bookA, "Dune", daysAgo: 3, minutes: 5), session(bookA, "Dune", daysAgo: 4, minutes: 5)])
    check("today alone is a streak of 1 after a gap", gap.currentStreak == 1)
    check("the longest streak is found in the past", gap.longestStreak == 3, "\(gap.longestStreak)")
    let thin = stats([session(bookA, "Dune", daysAgo: 0, minutes: 0.4), session(bookA, "Dune", daysAgo: 1, minutes: 0.4)])
    check("under a minute in a day does not make a streak", thin.currentStreak == 0)

    let week = stats([session(bookA, "Dune", daysAgo: 6, minutes: 10), session(bookA, "Dune", daysAgo: 7, minutes: 100)])
    check("'last 7 days' is today and the six before it", week.minutesLast7Days == 10, "\(week.minutesLast7Days)")
    check("…while the total keeps everything", week.minutesTotal == 110)
    check("old sessions fall off the chart but not the total", week.daily.map(\.minutes).reduce(0, +) == 110)
    check("a 3-day chart", stats([session(bookA, "Dune", daysAgo: 5, minutes: 7)], days: 3).daily.count == 3 && stats([], days: 0).daily.isEmpty)

    let edge = stats([
        ReadingSession(bookID: bookA, title: "Dune", end: at(daysAgo: 1, hour: 23, minute: 59), minutes: 10, progressStart: 0, progressEnd: 0.1, audio: false),
        ReadingSession(bookID: bookA, title: "Dune", end: at(daysAgo: 0, hour: 0, minute: 1), minutes: 10, progressStart: 0, progressEnd: 0.1, audio: false),
    ])
    check("11:59pm and 12:01am are different days", edge.minutesToday == 10 && edge.daily[12].minutes == 10 && edge.currentStreak == 2, "\(edge.minutesToday) \(edge.daily[12].minutes) \(edge.currentStreak)")

    let two = stats([
        session(bookA, "Dune", daysAgo: 0, minutes: 10), session(bookB, "Hyperion", daysAgo: 1, minutes: 60, audio: true),
        session(bookA, "Dune (renamed)", daysAgo: 2, minutes: 15),
    ])
    check("books ranked by time", two.perBook.map(\.bookID) == [bookB, bookA], "\(two.perBook.map(\.title))")
    check("minutes add up per book", two.perBook.first?.minutes == 60 && two.perBook.last?.minutes == 25)
    check("a book keeps its audio flag", two.perBook.first?.audio == true)
    let ties = stats([session(bookA, "Zebra", daysAgo: 0, minutes: 10), session(bookB, "Aardvark", daysAgo: 0, minutes: 10)])
    check("ties sort by title", ties.perBook.map(\.title) == ["Aardvark", "Zebra"])
    let junk = stats([session(bookA, "Dune", daysAgo: 0, minutes: 0), session(bookA, "Dune", daysAgo: 0, minutes: -5), session(bookA, "Dune", daysAgo: 0, minutes: .nan), session(bookA, "Dune", daysAgo: 0, minutes: 12)])
    check("zero, negative and NaN minutes are ignored", junk.minutesTotal == 12 && junk.sessionCount == 1)

    check("duration: minutes", ReadingStats.duration(minutes: 42.2) == "42m")
    check("duration: hours", ReadingStats.duration(minutes: 65) == "1h 05m" && ReadingStats.duration(minutes: 120) == "2h 00m")
    check("duration: nothing", ReadingStats.duration(minutes: 0) == "0m" && ReadingStats.duration(minutes: 0.2) == "0m")

    // a session survives the JSON round trip the log uses
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
    let original = session(bookA, "Dune", daysAgo: 3, minutes: 12.5, audio: true)
    let round = try? dec.decode([ReadingSession].self, from: enc.encode([original]))
    check("sessions round-trip through the log file", round == [original], "\(String(describing: round))")
}


@MainActor
func runTrendChecks() {
    section("Reading trends and the finish forecast")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    cal.firstWeekday = 2   // weeks run Monday to Sunday
    // Wed 14 Feb 2024, 15:00 UTC
    let now = Date(timeIntervalSince1970: 1_707_922_800)
    func at(daysAgo: Int, hour: Int = 12) -> Date {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
    let book = UUID()
    func sit(_ daysAgo: Int, _ minutes: Double, from: Double = 0, to: Double = 0.1, _ id: UUID? = nil) -> ReadingSession {
        ReadingSession(bookID: id ?? book, title: "T", end: at(daysAgo: daysAgo), minutes: minutes, progressStart: from, progressEnd: to, audio: false)
    }
    func summary(_ s: [ReadingSession], calendar: Calendar? = nil) -> ReadingTrends.Summary {
        ReadingTrends.summary(s, now: now, calendar: calendar ?? cal)
    }

    let empty = summary([])
    check("no sittings: eight empty weeks and nothing to compare", empty.weeks.count == 8 && empty.weeks.allSatisfy { $0.minutes == 0 }
          && empty.thisWeekMinutes == 0 && empty.changeFromLastWeek == nil && empty.activeDays == 0 && empty.bestDay == nil)

    // this week (Mon 12 Feb): 12th 10, 13th 20, 14th 30.  Last week: Sun 11th 40, Thu 8th 20, Wed 7th 20.
    let log = [sit(2, 10), sit(1, 20), sit(0, 30), sit(3, 40), sit(6, 20), sit(7, 20)]
    let t = summary(log)
    check("this week and last are summed from Monday", t.thisWeekMinutes == 60 && t.lastWeekMinutes == 80, "\(t.thisWeekMinutes)/\(t.lastWeekMinutes)")
    check("the current week is the last one and weeks run oldest first",
          t.weeks.last?.start == at(daysAgo: 2, hour: 0) && t.weeks[6].start == at(daysAgo: 9, hour: 0) && t.weeks.map(\.start) == t.weeks.map(\.start).sorted())
    check("the change from last week is a fraction", t.changeFromLastWeek == -0.25, "\(String(describing: t.changeFromLastWeek))")
    check("active days and the average on one", t.activeDays == 6 && abs(t.averageActiveDayMinutes - 140.0 / 6) < 0.0001, "\(t.activeDays) \(t.averageActiveDayMinutes)")
    check("the best day is the one with the most time", t.bestDay?.minutes == 40 && t.bestDay?.date == at(daysAgo: 3, hour: 0))

    var sunday = cal
    sunday.firstWeekday = 1
    check("weeks start where the calendar says (Sunday puts the 11th in this week)", summary(log, calendar: sunday).thisWeekMinutes == 100)

    check("a sitting too short to count does not make an active day",
          summary([sit(0, 0.4)]).activeDays == 0 && summary([sit(0, .nan), sit(0, -3)]).thisWeekMinutes == 0)
    check("sittings older than the chart fall off the weeks", summary([sit(200, 50)]).weeks.allSatisfy { $0.minutes == 0 })

    // finish forecast: 0 → 0.3 over the 7 days from the 8th to today; 0.7 left at 0.3 / 7 a day → 17 days
    let reading = [sit(6, 20, from: 0, to: 0.1), sit(3, 20, from: 0.1, to: 0.2), sit(0, 20, from: 0.2, to: 0.3)]
    let f = ReadingTrends.forecast(reading, bookID: book, progress: 0.3, now: now, calendar: cal)
    check("the forecast spreads what was read over the days since the first sitting", f?.daysLeft == 17, "\(String(describing: f))")
    check("…and lands on that day", f?.finish == cal.date(byAdding: .day, value: 17, to: cal.startOfDay(for: now)))
    check("one sitting is not enough to go on", ReadingTrends.forecast([sit(0, 20, from: 0, to: 0.1)], bookID: book, progress: 0.1, now: now, calendar: cal) == nil)
    check("another book's sittings are not this book's", ReadingTrends.forecast(reading, bookID: UUID(), progress: 0.3, now: now, calendar: cal) == nil)
    check("re-reading what was already read is not progress",
          ReadingTrends.forecast([sit(2, 20, from: 0.5, to: 0.2), sit(0, 20, from: 0.4, to: 0.3)], bookID: book, progress: 0.3, now: now, calendar: cal) == nil)
    check("old sittings do not set the pace", ReadingTrends.forecast([sit(40, 20, from: 0, to: 0.1), sit(30, 20, from: 0.1, to: 0.2)], bookID: book, progress: 0.2, now: now, calendar: cal) == nil)
    check("a finished book has no forecast", ReadingTrends.forecast(reading, bookID: book, progress: 0.995, now: now, calendar: cal) == nil
          && ReadingTrends.forecast(reading, bookID: book, progress: .nan, now: now, calendar: cal) == nil)
    check("a finish more than a year off is not offered",
          ReadingTrends.forecast([sit(6, 5, from: 0, to: 0.003), sit(0, 5, from: 0.003, to: 0.006)], bookID: book, progress: 0.006, now: now, calendar: cal) == nil)

    check("the label says it plainly",
          ReadingTrends.label(.init(daysLeft: 1, finish: now)) == "Done by tomorrow at this pace"
          && ReadingTrends.label(.init(daysLeft: 4, finish: now)) == "Done in about 4 days at this pace"
          && ReadingTrends.label(.init(daysLeft: 17, finish: now)).hasPrefix("Done around "))
}


@MainActor
func runLinkURLChecks() {
    section("BookMaster link addresses")
    let code = "0123456789abcdef0123456789abcdef"
    func u(_ s: String) -> URL { URL(string: s)! }

    check("the flow starts on BookMaster's link page", BMLinkURL.start.host == "bookmaster.pages.dev" && BMLinkURL.start.path == "/link/pageturner", BMLinkURL.start.absoluteString)
    let from = URLComponents(url: BMLinkURL.start, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "from" }?.value
    check("…telling it production Pageturner asked (an origin BookMaster accepts)", from == "https://pageturner.pages.dev", from ?? "nil")

    check("the return address yields the code", BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/?bm-link=\(code)")) == code)
    check("a preview build's address does too", BMLinkURL.code(fromReturn: u("https://feature-x.pageturner.pages.dev/?bm-link=\(code)")) == code)
    check("a path and fragment around it don't matter", BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/index.html?x=1&bm-link=\(code)#top")) == code)
    check("another host is refused", BMLinkURL.code(fromReturn: u("https://evil.example/?bm-link=\(code)")) == nil)
    check("a host that merely contains the name is refused", BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev.evil.example/?bm-link=\(code)")) == nil
          && BMLinkURL.code(fromReturn: u("https://notpageturner.pages.dev/?bm-link=\(code)")) == nil)
    check("plain http is refused", BMLinkURL.code(fromReturn: u("http://pageturner.pages.dev/?bm-link=\(code)")) == nil)
    check("no code, no link", BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/")) == nil
          && BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/?bm-link=")) == nil)
    check("a code that is too short or has odd characters is refused", BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/?bm-link=abc")) == nil
          && BMLinkURL.code(fromReturn: u("https://pageturner.pages.dev/?bm-link=abcdefgh%22%3Ex")) == nil)

    check("the app's own scheme yields the code", BMLinkURL.code(fromAppURL: u("pageturner://link?code=\(code)")) == code)
    check("…only on the link host", BMLinkURL.code(fromAppURL: u("pageturner://open?code=\(code)")) == nil)
    check("…and only for this scheme", BMLinkURL.code(fromAppURL: u("other://link?code=\(code)")) == nil)
    check("either shape through code(from:)", BMLinkURL.code(from: u("pageturner://link?code=\(code)")) == code
          && BMLinkURL.code(from: u("https://pageturner.pages.dev/?bm-link=\(code)")) == code
          && BMLinkURL.code(from: u("https://bookmaster.pages.dev/dashboard")) == nil)

    check("BookMaster's pages open in the sheet", BMLinkURL.isBookMasterPage(u("https://bookmaster.pages.dev/link/pageturner?from=x")))
    check("nothing else does", !BMLinkURL.isBookMasterPage(u("https://evil.example/")) && !BMLinkURL.isBookMasterPage(u("https://bookmaster.pages.dev.evil.example/"))
          && !BMLinkURL.isBookMasterPage(u("http://bookmaster.pages.dev/")) && !BMLinkURL.isBookMasterPage(u("https://sub.bookmaster.pages.dev/")))
}

private extension JumpHistory {
    /// `record` on a throwaway copy, to ask "would it be kept?" in one expression.
    func recordedCopy(origin: Spot, landed: Spot) -> Bool {
        var copy = self
        return copy.record(origin: origin, landed: landed)
    }
}

@MainActor
func runGroupingChecks() {
    section("Audiobook grouping")
    func item(_ path: String, album: String = "") -> AudioGrouping.Item {
        .init(url: URL(fileURLWithPath: path), album: album)
    }

    check("stem drops trailing numbers and separators", AudioGrouping.stem("Dune - 04.mp3") == "dune"
          && AudioGrouping.stem("dune_12.m4b") == "dune")
    check("stem drops leading numbers", AudioGrouping.stem("07 - Dune.mp3") == "dune")
    check("stem drops disc and part words anywhere at the tail", AudioGrouping.stem("Dune CD2 - 04.mp3") == "dune"
          && AudioGrouping.stem("Dune - Part 03.mp3") == "dune" && AudioGrouping.stem("Dune pt4.mp3") == "dune")
    check("a number-only name has no stem", AudioGrouping.stem("01.mp3").isEmpty && AudioGrouping.stem("1984 - 01.mp3").isEmpty)
    check("a different book keeps its stem", AudioGrouping.stem("Dune2 - 01.mp3") == "dune2"
          && AudioGrouping.stem("Dune Messiah - 01.mp3") == "dune messiah"
          && AudioGrouping.stem("Harry Potter 2.mp3") == "harry potter 2")
    check("track words leave the same stem", AudioGrouping.stem("Track 01.mp3") == AudioGrouping.stem("Track 02.mp3"))

    check("disc folders recognised", AudioGrouping.isDisc("CD 1") && AudioGrouping.isDisc("CD2")
          && AudioGrouping.isDisc("Disc 02") && AudioGrouping.isDisc("Part 3") && AudioGrouping.isDisc("pt4"))
    check("ordinary folders are not discs", !AudioGrouping.isDisc("Book") && !AudioGrouping.isDisc("Extras")
          && !AudioGrouping.isDisc("CD 1-2") && !AudioGrouping.isDisc("Dune (unabridged)"))

    let sameDir = AudioGrouping.groups(of: [item("/in/Dune - 01.mp3"), item("/in/Dune - 02.mp3")])
    check("parts of one book in one folder group", sameDir.count == 1 && sameDir[0].count == 2)
    let twoBooks = AudioGrouping.groups(of: [item("/in/Dune - 01.mp3"), item("/in/Dune - 02.mp3"),
                                             item("/in/Emma - 01.mp3"), item("/in/Emma - 02.mp3")])
    check("two books that shared a folder stay two books", twoBooks.count == 2)
    let albumSplit = AudioGrouping.groups(of: [item("/in/01.mp3", album: "Dune"), item("/in/02.mp3", album: "Dune"),
                                               item("/in/03.mp3", album: "Emma")])
    check("album tags split an otherwise anonymous folder", albumSplit.count == 2
          && albumSplit[0].count == 2 && albumSplit[1].count == 1)
    let albumMerge = AudioGrouping.groups(of: [item("/a/01.mp3", album: "Dune"), item("/b/01.mp3", album: "Dune")])
    check("an album tag spans folders", albumMerge.count == 1 && albumMerge[0].count == 2)
    let discs = AudioGrouping.groups(of: [item("/Book/CD 1/01.mp3"), item("/Book/CD 1/02.mp3"),
                                          item("/Book/CD 2/01.mp3"), item("/Book/CD 2/02.mp3")])
    check("sibling disc folders merge into one book", discs.count == 1 && discs[0].count == 4)
    let discOrder = AudioGrouping.groups(of: [item("/Book/CD 10/01.mp3"), item("/Book/CD 2/02.mp3"),
                                              item("/Book/CD 2/01.mp3")])
    check("'CD 2' tracks come before 'CD 10'", discOrder.count == 1
          && discOrder[0].map { $0.url.path } == ["/Book/CD 2/01.mp3", "/Book/CD 2/02.mp3", "/Book/CD 10/01.mp3"])
    let loneDisc = AudioGrouping.groups(of: [item("/Book/CD 1/01.mp3"), item("/Book/02.mp3")])
    check("a lone disc folder doesn't drag the parent's loose files in", loneDisc.count == 2)
    let bare = AudioGrouping.groups(of: [item("/in/01.mp3"), item("/in/02.mp3")])
    check("nameless files still group by folder, as before", bare.count == 1 && bare[0].count == 2)
    let chOrder = AudioGrouping.groups(of: [item("/in/Dune - 10.mp3"), item("/in/Dune - 2.mp3")])
    check("'ch2' sorts before 'ch10'", chOrder[0].map { $0.url.lastPathComponent } == ["Dune - 2.mp3", "Dune - 10.mp3"])

    func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/in/\($0)") } }
    check("a shared stem names the group", AudioGrouping.title(for: urls("Dune - 01.mp3", "Dune - 09.mp3")) == "Dune")
    check("a one-file group has no stem title", AudioGrouping.title(for: urls("Dune - 01.mp3")) == nil)
    check("mixed stems spell nothing", AudioGrouping.title(for: urls("Dune - 01.mp3", "Emma - 01.mp3")) == nil)
    check("nameless files spell nothing", AudioGrouping.title(for: urls("01.mp3", "02.mp3")) == nil)
    check("a medium word is not a title", AudioGrouping.title(for: urls("Track - 01.mp3", "Track - 02.mp3")) == nil)
    check("the stem title keeps its words", AudioGrouping.title(for: urls("harry potter 2 - 01.mp3", "harry potter 2 - 02.mp3")) == "Harry Potter 2")
}

func runSleepChecks() async {
    section("Sleep timer")
    check("120s of media at 2× is a minute away", SleepTiming.wall(remainingMedia: 120, rate: 2) == 60)
    check("60s at 1× is a minute", SleepTiming.wall(remainingMedia: 60, rate: 1) == 60)
    check("a boundary already reached is no wait", SleepTiming.wall(remainingMedia: -5, rate: 1) == 0)
    check("a stopped rate cannot divide by zero",
          SleepTiming.wall(remainingMedia: 60, rate: 0) == 600, "\(SleepTiming.wall(remainingMedia: 60, rate: 0))")

    let now = Date()
    let past = now.addingTimeInterval(-1)
    let future = now.addingTimeInterval(60)
    check("a rung bell while playing pauses", SleepTiming.shouldPause(now: now, deadline: past, isPlaying: true, chapterMode: false))
    check("a minute timer elapses even while paused", SleepTiming.shouldPause(now: now, deadline: past, isPlaying: false, chapterMode: false))
    check("chapter mode on a paused player stays set for play() to re-aim",
          !SleepTiming.shouldPause(now: now, deadline: past, isPlaying: false, chapterMode: true))
    check("a bell before its deadline does nothing", !SleepTiming.shouldPause(now: now, deadline: future, isPlaying: true, chapterMode: false))

    section("Audio focus")
    let focus = AudioFocus.shared
    await focus.register("audiobook", pause: {})
    check("the only sound registered owns the session", await focus.soleOwner("audiobook"))
    check("an id that is not registered cannot be the owner", await !focus.soleOwner("readaloud"))
    await focus.register("readaloud", pause: {})
    check("a sibling registered means the session is shared", await !focus.soleOwner("audiobook"))
    await focus.unregister("readaloud")
    check("back to one", await focus.soleOwner("audiobook"))
    await focus.unregister("audiobook")
}

func runCurlChecks() {
    section("Page curl")
    let w = 390.0, h = 844.0
    let cols = 6, rows = 8
    let src = PageCurl.source(columns: cols, rows: rows, width: w, height: h)
    check("the grid covers the sheet", src.count == (cols + 1) * (rows + 1)
        && src.first == PageCurl.Point(x: 0, y: 0) && src.last == PageCurl.Point(x: w, y: h))

    let still = PageCurl.Grab(origin: .init(x: w, y: h / 2), touch: .init(x: w, y: h / 2))
    check("nothing pulled is the flat page", PageCurl.positions(columns: cols, rows: rows, width: w, height: h, grab: still) == src)
    check("nothing pulled draws no fold", PageCurl.foldLine(width: w, height: h, grab: still) == nil)
    check("nothing pulled is no progress", PageCurl.progress(width: w, height: h, grab: still) == 0)

    // a pull from the right edge, most of the way across
    let pull = PageCurl.Grab(origin: .init(x: w, y: h / 2), touch: .init(x: w * 0.4, y: h / 2))
    let warped = PageCurl.positions(columns: cols, rows: rows, width: w, height: h, grab: pull)
    check("warped stays finite", warped.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    check("the spine side holds still", warped[0].x < 0.5 && warped[0].y < 0.5,
        "\(warped[0].x),\(warped[0].y)")
    // the free edge is face-down on the finger: the sheet point the finger
    // caught lands under it — its destination x is the touch's x exactly
    check("the grabbed edge follows the finger", abs(warped[cols].x - w * 0.4) < 0.5
        && abs(warped[cols].y - 0) < 0.5, "\(warped[cols].x),\(warped[cols].y) expect \(w * 0.4),0")

    if let fold = PageCurl.foldLine(width: w, height: h, grab: pull) {
        let onPage: (PageCurl.Point) -> Bool = { $0.x >= -0.5 && $0.x <= w + 0.5 && $0.y >= -0.5 && $0.y <= h + 0.5 }
        check("the crease meets the page's edges", onPage(fold.a) && onPage(fold.b) && fold.a != fold.b)
        // a straight pull across the middle: the crease is a vertical line
        check("a straight pull's crease is vertical", abs(fold.a.x - fold.b.x) < 0.001, "\(fold.a),\(fold.b)")
    } else {
        check("a pulled page has a crease", false)
    }

    // deeper pulls turn more, capped at a full turn
    let half = PageCurl.progress(width: w, height: h, grab: pull)
    let deep = PageCurl.Grab(origin: .init(x: w, y: h / 2), touch: .init(x: -w, y: h / 2))
    check("pulling further turns further", half > 0 && half < 1
        && PageCurl.progress(width: w, height: h, grab: deep) >= half)
    check("travel is the whole sheet and the roll", PageCurl.travel(width: w, height: h, grab: pull) > w)

    // the same pull from the left edge (a backward turn) moves the other side
    let back = PageCurl.Grab(origin: .init(x: 2, y: h / 2), touch: .init(x: w * 0.6, y: h / 2))
    let backWarp = PageCurl.positions(columns: cols, rows: rows, width: w, height: h, grab: back)
    check("a backward pull holds the right side still", abs(backWarp[cols].x - w) < 0.5 && backWarp[cols].y < 0.5,
        "\(backWarp[cols].x),\(backWarp[cols].y)")

    // a tilted pull (corner grabbed) still folds cleanly
    let corner = PageCurl.Grab(origin: .init(x: w, y: h), touch: .init(x: w * 0.45, y: h * 0.4))
    check("a corner pull stays finite", PageCurl.positions(columns: cols, rows: rows, width: w, height: h, grab: corner)
        .allSatisfy { $0.x.isFinite && $0.y.isFinite })
    check("a corner pull has a crease", PageCurl.foldLine(width: w, height: h, grab: corner) != nil)

    // the leaf's two layers: neither folds back over itself, so the back can be drawn whole over the front
    let fineCols = 22, fineRows = 28
    let fine = PageCurl.source(columns: fineCols, rows: fineRows, width: w, height: h)
    let whole = PageCurl.positions(columns: fineCols, rows: fineRows, width: w, height: h, grab: corner)
    let split = PageCurl.layers(columns: fineCols, rows: fineRows, width: w, height: h, grab: corner)
    let cdir = (corner.touch - corner.origin).normalized
    // each vertex's depth along the drag, and where along it each layer puts it
    let depth = fine.map { ($0 - corner.origin).dot(cdir) }
    let order = fine.indices.sorted { depth[$0] < depth[$1] }
    let frontAlong = order.map { (split.front[$0] - corner.origin).dot(cdir) }
    check("the front layer never doubles back", zip(frontAlong, frontAlong.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 })
    if let layer = split.back {
        let backAlong = order.map { (layer[$0] - corner.origin).dot(cdir) }
        check("the back layer never doubles back", zip(backAlong, backAlong.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 })
        // together they are the one warp: each vertex is where the whole sheet puts it, in whichever layer holds it
        let crestDepth = PageCurl.foldDepth(touchDistance: (corner.touch - corner.origin).length) - .pi * PageCurl.rollRadius / 2
        check("the layers are the whole warp", fine.indices.allSatisfy { i in
            let mine = depth[i] >= crestDepth ? split.front[i] : layer[i]
            return abs(mine.x - whole[i].x) < 1e-6 && abs(mine.y - whole[i].y) < 1e-6
        })
        // what a layer does not hold is gathered on the crest, where it draws nothing
        let backGathered = fine.indices.filter { depth[$0] > crestDepth }.map { (layer[$0] - corner.origin).dot(cdir) }
        check("the back holds still where the front is", (backGathered.max() ?? 0) - (backGathered.min() ?? 0) < 1e-6)
    } else {
        check("a corner pull has a back", false)
    }
    check("the whole warp does fold back over itself", {
        let along = order.map { (whole[$0] - corner.origin).dot(cdir) }
        return !zip(along, along.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 }
    }())
    let rest = PageCurl.layers(columns: fineCols, rows: fineRows, width: w, height: h, grab: still)
    check("nothing pulled is a flat front and no back", rest.front == fine && rest.back == nil)
}
