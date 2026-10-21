import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Drives the app's real BookMaster client against a live local stack:
//   Swift client -> Pageturner Pages Function (:8789) -> BookMaster (:8788) -> D1

setvbuf(stdout, nil, _IONBF, 0)
let harness = ProcessInfo.processInfo.environment["BM_HARNESS"] ?? FileManager.default.currentDirectoryPath
let work = harness + "/.work"
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)  \(detail())") }
}
func section(_ s: String) { print("\n== \(s)") }

@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
func q(_ sql: String) -> [[String: Any]] {
    let escaped = sql.replacingOccurrences(of: "'", with: "'\\''")
    let out = sh("python3 '\(harness)/q.py' '\(escaped)'")
    return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
}
func s(_ row: [String: Any]?, _ key: String) -> String? {
    guard let v = row?[key], !(v is NSNull) else { return nil }
    return "\(v)"
}
func waitForBookMaster(up: Bool, seconds: Int = 60) -> Bool {
    for _ in 0..<seconds {
        let code = sh("curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8788/api/auth/me")
        if (code == "401") == up { return true }
        usleep(1_000_000)
    }
    return false
}


// Library data: dates, authors, and old files — no servers needed.
@MainActor
func runData() async {
    section("Dates (the 31-year drift)")
    func mk() -> Book { Book(id: UUID(), title: "T", author: "A", fileName: "x.epub", fileNames: ["x.epub"], addedAt: Date()) }
    let now = Date()
    // what an earlier build wrote: JSONEncoder's default — seconds since 2001
    let legacy = """
    [{"id":"\(UUID().uuidString)","title":"Old","author":"A","fileName":"x.epub",
      "addedAt":\(now.timeIntervalSinceReferenceDate),"lastOpenedAt":\(now.timeIntervalSinceReferenceDate)}]
    """
    if let books = try? JSONDecoder().decode([Book].self, from: Data(legacy.utf8)), let b = books.first {
        check("an earlier build's 2001-based dates are read as today, not 1995", abs(b.addedAt.timeIntervalSince(now)) < 5, "\(b.addedAt)")
        check("lastOpenedAt repaired too", b.lastOpenedAt.map { abs($0.timeIntervalSince(now)) < 5 } ?? false)
    } else { check("legacy library.json still loads", false) }

    let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
    var book = mk(); book.lastOpenedAt = now
    var cycle = book
    for _ in 0..<5 {   // five saves and relaunches
        guard let d = try? enc.encode([cycle]), let back = try? JSONDecoder().decode([Book].self, from: d).first else { check("round trip decodes", false); return }
        cycle = back
    }
    check("five save/load cycles do not move the date", abs(cycle.addedAt.timeIntervalSince(book.addedAt)) < 1, "\(cycle.addedAt) vs \(book.addedAt)")
    check("nor lastOpenedAt", abs((cycle.lastOpenedAt ?? .distantPast).timeIntervalSince(now)) < 1)

    let web = """
    [{"id":"\(UUID().uuidString)","title":"W","author":"A","fileName":"x.epub","addedAt":1760000000000}]
    """
    if let b = (try? JSONDecoder().decode([Book].self, from: Data(web.utf8)))?.first {
        check("a web backup's millisecond date is read correctly", abs(b.addedAt.timeIntervalSince1970 - 1_760_000_000) < 1, "\(b.addedAt)")
    } else { check("web-shaped record decodes", false) }

    let ancient = """
    [{"id":"\(UUID().uuidString)","title":"X","author":"A","fileName":"x.epub","addedAt":-150000000.0}]
    """
    if let b = (try? JSONDecoder().decode([Book].self, from: Data(ancient.utf8)))?.first {
        check("a date drifted past repair falls back to now instead of 1960s", abs(b.addedAt.timeIntervalSince(Date())) < 5, "\(b.addedAt)")
    } else { check("drifted record decodes", false) }

    section("Old files and new fields")
    let minimal = """
    [{"id":"\(UUID().uuidString)","title":"Min","author":"A","fileName":"x.epub","addedAt":\(now.timeIntervalSince1970)}]
    """
    if let b = (try? JSONDecoder().decode([Book].self, from: Data(minimal.utf8)))?.first {
        check("a file with none of the newer keys loads", b.bookmasterId == nil && b.bookmarks.isEmpty && b.fileNames == ["x.epub"])
    } else { check("minimal record decodes", false) }
    var pinned = mk(); pinned.bookmasterId = "abc"; pinned.bmStatus = "reading"; pinned.bmRating = 4; pinned.bmRemotePercent = 12.5; pinned.bmUpNext = true
    if let d = try? enc.encode([pinned]), let back = try? JSONDecoder().decode([Book].self, from: d).first {
        check("BookMaster fields survive a save", back.bookmasterId == "abc" && back.bmStatus == "reading" && back.bmRating == 4 && back.bmRemotePercent == 12.5 && back.bmUpNext == true)
    } else { check("BookMaster fields round trip", false) }

    section("Authors")
    check("Last, First -> First Last", sendableAuthor("Herbert, Frank") == "Frank Herbert")
    check("role tags dropped", sendableAuthor("Frank Herbert (Author)") == "Frank Herbert", sendableAuthor("Frank Herbert (Author)"))
    check("two authors joined with & are left alone", sendableAuthor("Neil Gaiman & Terry Pratchett") == "Neil Gaiman & Terry Pratchett", sendableAuthor("Neil Gaiman & Terry Pratchett"))
    check("two authors joined with ; are left alone", sendableAuthor("A One; B Two") == "A One; B Two", sendableAuthor("A One; B Two"))
    check("empty stays empty", sendableAuthor("") == "")

    section("Title and author matching")
    check("series suffix", BMShelf.titlesAgree("Dune (Dune Chronicles, #1)", "Dune"))
    check("subtitle after a colon", BMShelf.titlesAgree("Dune: Deluxe Edition", "Dune"))
    check("file-name phrasing 'Title - Author'", BMShelf.titlesAgree("Dune - Frank Herbert", "Dune"))
    check("different books with a shared start stay apart", !BMShelf.titlesAgree("Dune Messiah", "Dune"))
    check("longer prefix titles do agree (8+ chars)", BMShelf.titlesAgree("Project Hail Mary: A Novel", "Project Hail Mary"))
    check("author: reordered name agrees", BMShelf.authorsAgree("Herbert, Frank", "Frank Herbert"))
    check("author: different people disagree", !BMShelf.authorsAgree("Stephen King", "Frank Herbert"))
    check("author: missing never decides", BMShelf.authorsAgree("", "Frank Herbert") && BMShelf.authorsAgree("Frank Herbert", nil))

    runBookText()
    runBackupChecks()
    await runAudioChecks()
    await runQueueChecks()
    runLogic()
    runGroupingChecks()
    runCurlChecks()
    await runSleepChecks()
    runStatsChecks()
    runTrendChecks()
    runAutoBackupChecks()
    runLinkURLChecks()
    runVoiceChecks()
    runSpeechTextChecks()
    runSampleChecks()
    runReadingSpanChecks()
    runNeuralChecks()
    runSpokenWordsChecks()
    runShelfChecks()
    runSuiteChecks()
    runChatChecks()
    runWebAppsChecks()
    runDeepLinkChecks()
    runInboxChecks()
    runQuestLogChecks()
    runDriveChecks()
    runDriveBooksChecks()
    runGoodreadsChecks()
    runPaceChecks()
    runQolChecks()
    runOPDSChecks()
    runVoiceDSPChecks()
    runPlayheadChecks()
    runCatalogueChecks()
    runHardcoverChecks()
    runTextBook()
}

@MainActor
func run() async {
    let bm = BookMaster.shared
    bm.unlink()
    let code = ProcessInfo.processInfo.environment["BM_CODE"] ?? ""

    // ------------------------------------------------------------------ link
    section("Link")
    // the code BookMaster really minted, as BookMaster's own return address carries it
    // (pageturnerLinkUrl in src/lib/presence.ts: `<from>/?bm-link=<code>`)
    check("the app reads the real minted code off BookMaster's return address",
          URL(string: "https://pageturner.pages.dev/?bm-link=\(code)").flatMap(BMLinkURL.code(from:)) == code, code)
    check("…and off a preview build's address",
          URL(string: "https://abc123.pageturner.pages.dev/?bm-link=\(code)").flatMap(BMLinkURL.code(from:)) == code)
    do {
        try await bm.redeem(code: code)
        check("redeems a real one-time code", bm.isLinked)
        check("learns the username", bm.user?.username == "pengu", "\(String(describing: bm.user))")
        check("learns the display name", bm.user?.displayName == "Andrew")
    } catch { check("redeems a real one-time code", false, "\(error)") }
    do {
        try await bm.redeem(code: code)
        check("a spent code is refused", false, "second redeem succeeded")
    } catch { check("a spent code is refused", true) }
    do {
        try await bm.redeem(code: "not-a-code")
        check("a bogus code is refused", false)
    } catch { check("a bogus code is refused", true) }

    // -------------------------------------------------------------- progress
    section("Progress")
    let author = sendableAuthor("Herbert, Frank")
    check("author reorders to display order", author == "Frank Herbert", author)
    var ref = BMBookRef(title: "Dune", author: author, isbn: nil, openLibraryId: nil, userBookId: nil)
    var pin: String?
    await bm.syncProgress(bookKey: "Dune", ref: ref, percent: 0.05, isAudio: false, pinned: { pin = $0 })
    check("first push is accepted and returns the shelf pin", pin != nil, "pin=\(String(describing: pin))")
    let shelf1 = q("select ub.id, ub.status, ub.format, ub.current_page, b.title, b.author from user_books ub join books b on b.id=ub.book_id join users u on u.id=ub.user_id where u.username='pengu'").first
    check("book landed on pengu's shelf", s(shelf1, "title") == "Dune", "\(String(describing: shelf1))")
    check("author stored in display order", s(shelf1, "author") == "Frank Herbert", s(shelf1, "author") ?? "nil")
    check("pin equals the shelf row id", s(shelf1, "id") == pin)
    check("status is reading", s(shelf1, "status") == "reading", s(shelf1, "status") ?? "nil")
    check("format is ebook", s(shelf1, "format") == "ebook", s(shelf1, "format") ?? "nil")
    check("percent stored (5)", s(shelf1, "current_page") == "5", s(shelf1, "current_page") ?? "nil")

    ref.userBookId = pin
    var repinned: String?
    await bm.syncProgress(bookKey: "Dune", ref: ref, percent: 0.06, isAudio: false, pinned: { repinned = $0 })
    check("a second push inside 30s is throttled", repinned == nil)

    // --------------------------------------------------------------- session
    section("Session")
    let before = (q("select count(*) c from reading_sessions").first?["c"] as? Int) ?? -1
    await bm.syncSession(ref: ref, percentStart: 0.05, percentEnd: 0.15, minutes: 12, at: Date())
    let sess = q("select s.pages_start, s.pages_end, s.duration_minutes, s.session_date from reading_sessions s join users u on u.id=s.user_id where u.username='pengu' order by s.rowid desc limit 1").first
    let after = (q("select count(*) c from reading_sessions").first?["c"] as? Int) ?? -1
    check("session row written", after == before + 1, "before \(before) after \(after)")
    check("pages 5 -> 15", s(sess, "pages_start") == "5" && s(sess, "pages_end") == "15", "\(String(describing: sess))")
    check("duration 12 minutes", s(sess, "duration_minutes") == "12", s(sess, "duration_minutes") ?? "nil")

    // ----------------------------------------------------------------- quote
    section("Quote")
    let okQuote = await bm.postQuote(ref: ref, content: "Fear is the mind-killer.", percent: 0.08)
    check("quote accepted", okQuote == .sent)
    let quote = q("select qu.content, qu.page_number from quotes qu join users u on u.id=qu.user_id where u.username='pengu' order by qu.rowid desc limit 1").first
    check("quote stored", s(quote, "content") == "Fear is the mind-killer.", "\(String(describing: quote))")

    // -------------------------------------------------------------- presence
    section("Presence")
    await bm.beat(place: "reader")
    var pres = q("select p.place, p.left_at, p.last_seen_at from app_presence p join users u on u.id=p.user_id where u.username='pengu' and p.app='pageturner'").first
    check("beat recorded with the place", s(pres, "place") == "reader", "\(String(describing: pres))")
    check("not marked as left", s(pres, "left_at") == nil)
    await bm.beat(leaving: true)
    pres = q("select p.left_at from app_presence p join users u on u.id=p.user_id where u.username='pengu' and p.app='pageturner'").first
    check("leaving sets left_at", s(pres, "left_at") != nil)
    bm.place = "stats"
    await bm.beat()
    pres = q("select p.place from app_presence p join users u on u.id=p.user_id where u.username='pengu' and p.app='pageturner'").first
    check("beat uses the current place", s(pres, "place") == "stats", s(pres, "place") ?? "nil")

    // ----------------------------------------------------- together + nudges
    section("Together")
    do {
        let t = try await bm.fetchTogether()
        check("partner decoded", t.partner?.name == "Kristen", "\(String(describing: t.partner?.name))")
        check("no nudges yet", t.nudges.isEmpty)
    } catch { check("together decodes", false, "\(error)") }

    // Kristen suggests a book to pengu through BookMaster's own API
    let bid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    _ = q("insert into books (id, title, author) values ('\(bid)', 'Hyperion', 'Dan Simmons')")
    let nudgeResp = sh("curl -s -b \(work)/cj2 -X POST http://127.0.0.1:8788/api/nudges -H 'content-type: application/json' -d '{\"book_id\":\"\(bid)\",\"note\":\"you will love this\"}'")
    check("setup: partner sends a suggestion", nudgeResp.contains("\"ok\":true"), nudgeResp)
    var nudgeId: String?
    do {
        let t = try await bm.fetchTogether()
        check("suggestion shows up", t.nudges.count == 1, "\(t.nudges.count)")
        check("suggestion fields decode", t.nudges.first?.title == "Hyperion" && t.nudges.first?.fromName == "Kristen" && t.nudges.first?.note == "you will love this", "\(String(describing: t.nudges.first))")
        nudgeId = t.nudges.first?.id
        check("notices decode", t.notices.allSatisfy { !$0.text.isEmpty })
        let told = NotificationPlan.plan(nudges: t.nudges, notices: t.notices, seen: [])
        check("the live suggestion becomes the notification the reader would see",
              told.items.first?.title == "Kristen suggested a book"
                && told.items.first?.body == "Hyperion by Dan Simmons — “you will love this”", "\(told.items)")
        check("…and is not announced twice", NotificationPlan.plan(nudges: t.nudges, notices: t.notices, seen: told.seen).items.isEmpty)
    } catch { check("together decodes with a nudge", false, "\(error)") }
    if let nudgeId {
        do {
            try await bm.answerNudge(id: nudgeId, accept: true)
            let row = q("select ub.status from user_books ub join books b on b.id=ub.book_id join users u on u.id=ub.user_id where u.username='pengu' and b.title='Hyperion'").first
            check("accepting shelves it as want_to_read", s(row, "status") == "want_to_read", "\(String(describing: row))")
        } catch { check("accept a suggestion", false, "\(error)") }
    }
    // pengu suggests a book Kristen doesn't have
    do {
        let to = try await bm.suggest(ref: BMBookRef(title: "Children of Dune", author: "Frank Herbert", isbn: nil, openLibraryId: nil, userBookId: nil), note: "next in the series")
        check("suggesting returns the partner's name", to == "Kristen", "\(String(describing: to))")
        let n = q("select n.note, n.status from nudges n join books b on b.id=n.book_id where b.title='Children of Dune'").first
        check("suggestion stored for the partner", s(n, "note") == "next in the series" && s(n, "status") == "pending", "\(String(describing: n))")
    } catch { check("suggest a book", false, "\(error)") }

    // -------------------------------------------------------------- comments
    section("Comments")
    do {
        try await bm.postComment(ref: ref, content: "Slow start but worth it")
        let c = q("select bc.content, bc.at_percent from book_comments bc join users u on u.id=bc.user_id where u.username='pengu' order by bc.rowid desc limit 1").first
        check("comment stored", s(c, "content") == "Slow start but worth it", "\(String(describing: c))")
    } catch { check("post a comment", false, "\(error)") }
    // Kristen, further along, leaves one that must stay sealed
    let dune = q("select book_id from user_books where id='\(pin ?? "")'").first
    let bookId = s(dune, "book_id") ?? ""
    _ = q("insert into book_comments (id, book_id, user_id, content, at_percent) select 'cmt\(bid)', '\(bookId)', id, 'The twist is wild', 80 from users where username='kristenkrae'")
    do {
        let thread = try await bm.fetchComments(ref: ref)
        check("thread decodes both comments", thread.comments.count == 2, "\(thread.comments.count)")
        let sealed = thread.comments.first { $0.displayName == "Kristen" }
        check("a note further on stays sealed (content nil, ahead true)", sealed?.content == nil && sealed?.ahead == true, "\(String(describing: sealed))")
        let mine = thread.comments.first { $0.userId == thread.you }
        check("own comment readable and recognised", mine?.content == "Slow start but worth it")
    } catch { check("fetch the thread", false, "\(error)") }

    // ------------------------------------------------------------------ chat
    section("Chat")
    do {
        let sent = try await bm.sendChat("hello from the reader")
        check("a message sends, and comes back as mine", sent.body == "hello from the reader" && sent.name == "Andrew", "\(sent)")
        check("…tagged as written in Pageturner", sent.app == "pageturner", sent.app)
        let row = q("select body, app, user_id from chat_messages where id=\(sent.id)").first
        check("it is in the shared room, in the database", s(row, "body") == "hello from the reader" && s(row, "app") == "pageturner", "\(String(describing: row))")

        let room = try await bm.fetchChat()
        check("the room reads back: the message, me, my partner, what I have read",
              room.messages.last?.id == sent.id && room.me.displayName == "Andrew"
              && room.partner?.displayName == "Kristen" && room.read.mine == sent.id && room.unread == 0, "\(room)")

        // Kristen answers from Kindred
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        _ = q("insert into chat_messages (user_id, body, app, created_at) select id, 'and from kindred', 'kindred', \(ms) from users where username='kristenkrae'")
        let answer = q("select id from chat_messages where body='and from kindred'").first
        let answerId = Int(s(answer, "id") ?? "") ?? -1
        let since = try await bm.fetchChat(after: sent.id)
        check("what came since is just her answer, unread, and says where it was written",
              since.messages.map(\.id) == [answerId] && since.unread == 1 && since.messages.first?.app == "kindred", "\(since.messages.map(\.id)) unread \(since.unread)")
        let feed = try await bm.fetchTogether()
        check("her message shows in my suite feed as the chat notice", BMChat.unreadNotice(feed.notices)?.id == "bookmaster:chat:\(answerId)",
              "\(feed.notices.map(\.id))")

        try await bm.markChatRead(upTo: answerId)
        let readRow = q("select r.last_read_id from chat_reads r join users u on u.id=r.user_id where u.username='pengu'").first
        check("telling the server I have read it is kept", s(readRow, "last_read_id") == "\(answerId)", "\(String(describing: readRow))")
        let afterRead = try await bm.fetchChat()
        let feedAfter = try await bm.fetchTogether()
        check("…so nothing is unread any more, and the notice is gone",
              afterRead.unread == 0 && afterRead.read.mine == answerId && BMChat.unreadNotice(feedAfter.notices) == nil)

        let older = try await bm.fetchChat(before: answerId)
        check("paging back returns what came before", older.messages.map(\.id) == [sent.id] && older.complete, "\(older.messages.map(\.id))")

        do {
            try await bm.removeChat(id: answerId)
            check("her message cannot be taken back by me", false, "removed")
        } catch { check("her message cannot be taken back by me", q("select id from chat_messages where id=\(answerId)").count == 1) }
        try await bm.removeChat(id: sent.id)
        check("my own can", q("select id from chat_messages where id=\(sent.id)").isEmpty)
        do {
            _ = try await bm.sendChat("   ")
            check("a blank message is refused", false)
        } catch { check("a blank message is refused", true) }
    } catch { check("chat", false, "\(error)") }
    // leave the room as it was found
    _ = q("delete from chat_messages")
    _ = q("delete from chat_reads")

    // -------------------------------------------------------------- overview
    section("Overview")
    do {
        let o = try await bm.fetchOverview()
        check("stats decode", o.stats.currentStreak >= 0 && o.stats.minutesRead >= 12, "\(o.stats)")
        check("quotes counted", o.stats.quotesSaved >= 1, "\(o.stats.quotesSaved)")
    } catch { check("overview decodes", false, "\(error)") }

    // ----------------------------------------------------------------- shelf
    section("Shelf pull")
    _ = q("update books set total_pages = 300 where title = 'Dune'")
    let lib = LibraryStore()
    func book(_ t: String, _ a: String) -> Book {
        Book(id: UUID(), title: t, author: a, fileName: "x.epub", fileNames: ["x.epub"], addedAt: Date())
    }
    let a = book("Dune (Dune Chronicles, #1)", "Frank Herbert (Author)")
    let b = book("Dune: Deluxe Edition", "Herbert, Frank")
    let c = book("Dune Messiah", "Frank Herbert")
    let d = book("Hyperion", "Dan Simmons")
    var stale = book("Dune", "Frank Herbert"); stale.bookmasterId = "deadbeefdeadbeef"
    lib.books = [a, b, c, d, stale]
    await bm.pullShelf(into: lib)
    check("series-suffixed title matches the shelf row", lib.books[0].bookmasterId == pin, "\(String(describing: lib.books[0].bookmasterId))")
    check("subtitle form matches too", lib.books[1].bookmasterId == pin, "\(String(describing: lib.books[1].bookmasterId))")
    check("a different book with a shared prefix does not", lib.books[2].bookmasterId == nil, "\(String(describing: lib.books[2].bookmasterId))")
    check("Hyperion matches its want_to_read row", lib.books[3].bmStatus == "want_to_read", "\(String(describing: lib.books[3].bmStatus))")
    check("a stale pin is replaced by the matched row", lib.books[4].bookmasterId == pin, "\(String(describing: lib.books[4].bookmasterId))")
    check("shelf status and position copied", lib.books[0].bmStatus == "reading" && lib.books[0].bmRemotePercent != nil, "\(String(describing: lib.books[0].bmStatus)) \(String(describing: lib.books[0].bmRemotePercent))")

    // ------------------------------------------------------------- stale pin
    section("Stale pin recovery")
    var staleRef = ref; staleRef.userBookId = "deadbeefdeadbeef"
    var recovered: String?
    await bm.syncProgress(bookKey: "Dune-stale", ref: staleRef, percent: 0.2, isAudio: false, force: true, pinned: { recovered = $0 })
    check("a dead pin is retried by title and re-pinned", recovered == pin, "recovered=\(String(describing: recovered)) pin=\(String(describing: pin))")
    do {
        let t = try await bm.fetchComments(ref: staleRef)
        check("comments fall back to title when the pin is dead", t.comments.count >= 1, "\(t.comments.count)")
    } catch { check("comments with a dead pin", false, "\(error)") }

    // ----------------------------------------------------------- finish read
    section("Finishing")
    await bm.syncProgress(bookKey: "Dune", ref: ref, percent: 1.0, isAudio: false, force: true, pinned: { _ in })
    let fin = q("select status from user_books where id='\(pin ?? "")'").first
    check("100% marks it read", s(fin, "status") == "read", s(fin, "status") ?? "nil")
    var audioRef = BMBookRef(title: "Project Hail Mary", author: "Andy Weir", isbn: nil, openLibraryId: nil, userBookId: nil)
    var audioPin: String?
    await bm.syncProgress(bookKey: "PHM", ref: audioRef, percent: 0.25, isAudio: true, pinned: { audioPin = $0 })
    audioRef.userBookId = audioPin
    let au = q("select format, current_page from user_books where id='\(audioPin ?? "")'").first
    check("audio pushes carry format audio", s(au, "format") == "audio", s(au, "format") ?? "nil")

    // -------------------------------------------------------- the deep bridge
    section("Deep bridge")
    var hobbitPin: String?
    do {
        // a book shelved by name goes on want_to_read, queued behind anything else up next
        let reply = try await bm.shelve(
            ref: BMBookRef(title: "The Hobbit", author: "J.R.R. Tolkien", isbn: nil, openLibraryId: nil, userBookId: nil),
            status: .wantToRead, upNext: true)
        check("shelve replies with the new row", reply.userBook?.title == "The Hobbit" && reply.userBook?.status == "want_to_read", "\(String(describing: reply.userBook))")
        check("queued as up next", reply.userBook?.upNext != nil)
        hobbitPin = reply.userBook?.userBookId
        // then edited the way the detail pane edits: status, stars, the queue
        let edit = try await bm.shelve(pin: hobbitPin, status: .reading, rating: .some(4), upNext: false)
        check("status moved to reading", edit.userBook?.status == "reading", "\(String(describing: edit.userBook?.status))")
        check("rating stored", edit.userBook?.rating == 4, "\(String(describing: edit.userBook?.rating))")
        check("unqueued", edit.userBook?.upNext == nil)
        if let hobbitPin {
            let row = q("select status, rating, up_next from user_books where id='\(hobbitPin)'").first
            check("the edit persisted", s(row, "status") == "reading" && s(row, "rating") == "4" && s(row, "up_next") == nil, "\(String(describing: row))")
        }
    } catch { check("shelve by name and pin", false, "\(error)") }

    // the detail page's whole read of one book (Dune was finished a moment ago —
    // at 100% nothing is sealed, and Kristen's own row rides along when she has it)
    _ = q("""
        insert or ignore into user_books (id, user_id, book_id, status, current_page, rating)
        values ('theirs-dune', (select id from users where username='kristenkrae'), '\(bookId)', 'read', 300, 5)
        """)
    do {
        let detail = try await bm.fetchBookDetail(pin: pin)
        check("detail names the catalogue book", detail.catalogue?.title == "Dune", "\(String(describing: detail.catalogue))")
        check("detail carries the shelf row", detail.book?.userBookId == pin)
        check("a finished book reads 100", detail.book?.status == "read", "\(String(describing: detail.book?.status))")
        check("its sessions come along", detail.sessions.count >= 1, "\(detail.sessions.count)")
        check("its quotes come along", detail.quotes.contains { $0.content == "Fear is the mind-killer." }, "\(detail.quotes.count)")
        check("the thread comes along, readable at 100%", detail.comments.count == 2 && detail.comments.allSatisfy { !$0.ahead }, "\(detail.comments)")
        check("the partner's row comes along", detail.theirs?.name == "Kristen" && detail.theirs?.rating == 5, "\(String(describing: detail.theirs))")
    } catch { check("fetch the book detail", false, "\(error)") }

    // the whole-list and per-book quotes reads
    do {
        let all = try await bm.fetchQuotes()
        check("the quotes list decodes with books", all.contains { $0.title == "Dune" && $0.content == "Fear is the mind-killer." }, "\(all.count)")
        if let pin {
            let own = try await bm.fetchQuotes(pin: pin)
            check("narrowed to one row", own.allSatisfy { $0.userBookId == pin } && !own.isEmpty, "\(own.count)")
        }
    } catch { check("fetch the quotes", false, "\(error)") }

    // badge wall, stat block, partner shelf, the wrap, the suggestions
    do {
        let wall = try await bm.fetchAchievements()
        check("the badge wall decodes", wall.allSatisfy { !$0.id.isEmpty }, "\(wall.count)")
    } catch { check("fetch the achievements", false, "\(error)") }
    do {
        let s = try await bm.fetchStats()
        check("level and xp decode", s.level >= 1 && s.xp >= 0, "level=\(s.level) xp=\(s.xp)")
        check("the month has days", !s.recentActivity.isEmpty, "\(s.recentActivity.count)")
    } catch { check("fetch the stats", false, "\(error)") }
    do {
        let theirs = try await bm.fetchPartnerShelf()
        check("the partner is Kristen", theirs.partner?.name == "Kristen", "\(String(describing: theirs.partner))")
        check("her year decodes", (theirs.booksThisYear ?? -1) >= 0 && theirs.year == Calendar.current.component(.year, from: Date()), "\(theirs)")
    } catch { check("fetch the partner shelf", false, "\(error)") }
    do {
        let year = try await bm.fetchWrapped()
        check("the wrap decodes", (year.booksRead ?? 0) >= 1 && (year.pagesRead ?? 0) > 0, "\(year)")
    } catch { check("fetch the wrap", false, "\(error)") }
    do {
        let recs = try await bm.fetchRecommendations()
        check("the lanes decode", recs.partner != nil, "\(String(describing: recs.partner))")
    } catch { check("fetch the recommendations", false, "\(error)") }
    do {
        let t = try await bm.fetchTogether()
        check("sent suggestions ride along", t.sent.contains { $0.title == "Children of Dune" && $0.toName == "Kristen" }, "\(t.sent)")
    } catch { check("together's sent list", false, "\(error)") }

    // rows that are yours to take back, each by name
    do {
        let sid = q("select id from reading_sessions order by rowid desc limit 1").first
        let qid = q("select id from quotes where content='Fear is the mind-killer.'").first
        let cid = q("select id from book_comments where content='Slow start but worth it'").first
        if let id = s(sid, "id") {
            try await bm.remove(.session, id: id)
            check("a session taken back", q("select id from reading_sessions where id='\(id)'").isEmpty)
        }
        if let id = s(qid, "id") {
            try await bm.remove(.quote, id: id)
            check("a quote taken back", q("select id from quotes where id='\(id)'").isEmpty)
        }
        if let id = s(cid, "id") {
            try await bm.remove(.comment, id: id)
            check("a comment taken back", q("select id from book_comments where id='\(id)'").isEmpty)
        }
        do {
            try await bm.remove(.session, id: "does-not-exist")
            check("removing a stranger's row 404s", false)
        } catch { check("removing a stranger's row 404s", true) }
    } catch { check("take rows back", false, "\(error)") }
    if let hobbitPin {
        do {
            _ = try await bm.shelve(pin: hobbitPin, unshelve: true)
            check("unshelve drops the row", q("select id from user_books where id='\(hobbitPin)'").isEmpty)
        } catch { check("unshelve a row", false, "\(error)") }
    }

    // ---------------------------------------------------------------- outage
    section("Outage and recovery")
    _ = system("'\(harness)/stack.sh' stop-bm-only >/dev/null 2>&1")
    check("BookMaster is down", waitForBookMaster(up: false, seconds: 20))
    // keep the Pageturner bridge alive (it was started with its own workerd) — restart it if the kill took it too
    if sh("curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8789/").trimmingCharacters(in: .whitespaces) != "200" {
        _ = system("'\(harness)/stack.sh' start-pt >/dev/null 2>&1 </dev/null")
        for _ in 0..<40 { if sh("curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8789/").contains("200") { break }; usleep(1_000_000) }
    }
    let sessionsBefore = (q("select count(*) c from reading_sessions").first?["c"] as? Int) ?? -1
    let quotesBefore = (q("select count(*) c from quotes").first?["c"] as? Int) ?? -1
    await bm.syncProgress(bookKey: "PHM", ref: audioRef, percent: 0.40, isAudio: true, force: true, pinned: { _ in })
    await bm.syncSession(ref: audioRef, percentStart: 0.25, percentEnd: 0.40, minutes: 30, at: Date())
    let queued = await bm.postQuote(ref: audioRef, content: "Question.", percent: 0.4)
    check("a quote made offline is reported as kept", queued == .queued)
    let queueFile = sh("ls ~/.local/share/bm-queue.json ~/Library/Application\\ Support/bm-queue.json 2>/dev/null | head -1").trimmingCharacters(in: .whitespacesAndNewlines)
    let queueJSON = (try? Data(contentsOf: URL(fileURLWithPath: queueFile))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    check("three pushes are parked, in order", queueJSON.map { $0["kind"] as? String ?? "" } == ["progress", "session", "quote"], "\(queueJSON.map { $0["kind"] ?? "?" }) file=\(queueFile)")
    // a newer position replaces the parked one, and does not overtake the session/quote
    await bm.syncProgress(bookKey: "PHM", ref: audioRef, percent: 0.50, isAudio: true, force: true, pinned: { _ in })
    let queueJSON2 = (try? Data(contentsOf: URL(fileURLWithPath: queueFile))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    check("newer progress replaces the parked progress (still 3 entries)", queueJSON2.count == 3, "\(queueJSON2.count)")
    check("the replacement joins at the back", queueJSON2.map { $0["kind"] as? String ?? "" } == ["session", "quote", "progress"], "\(queueJSON2.map { $0["kind"] ?? "?" })")

    _ = system("'\(harness)/stack.sh' start-bm >/dev/null 2>&1 </dev/null")
    check("BookMaster is back", waitForBookMaster(up: true, seconds: 60))
    await bm.flush()
    let sessionsAfter = (q("select count(*) c from reading_sessions").first?["c"] as? Int) ?? -1
    let quotesAfter = (q("select count(*) c from quotes").first?["c"] as? Int) ?? -1
    check("the parked session arrived", sessionsAfter == sessionsBefore + 1, "\(sessionsBefore) -> \(sessionsAfter)")
    check("the parked quote arrived", quotesAfter == quotesBefore + 1, "\(quotesBefore) -> \(quotesAfter)")
    let ph = q("select current_page from user_books where id='\(audioPin ?? "")'").first
    check("the newest position won (50)", s(ph, "current_page") == "50", s(ph, "current_page") ?? "nil")
    let queueJSON3 = (try? Data(contentsOf: URL(fileURLWithPath: queueFile))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    check("the queue is empty after the drain", queueJSON3.isEmpty, "\(queueJSON3.count)")

    // ---------------------------------------------------------------- unlink
    section("Unlink")
    bm.unlink()
    check("unlinked", !bm.isLinked)
    await bm.syncProgress(bookKey: "PHM", ref: audioRef, percent: 0.9, isAudio: true, force: true, pinned: { _ in })
    let ph2 = q("select current_page from user_books where id='\(audioPin ?? "")'").first
    check("nothing is sent once unlinked", s(ph2, "current_page") == "50", s(ph2, "current_page") ?? "nil")
}

if ProcessInfo.processInfo.environment["BM_ONLY"] == "data" {
    await runData()
} else {
    await run()
    await runData()
}
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
