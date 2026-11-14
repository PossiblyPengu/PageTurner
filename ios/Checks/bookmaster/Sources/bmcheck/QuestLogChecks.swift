import Foundation

// Checks for Quest Log's private chat inside Pageturner: what a stored message is, how it is opened and laid out,
// what may be sent. The cipher itself (CryptoKit) is checked by the simulator run against messages made by the web's recipe.

@MainActor
func runQuestLogChecks() {
    section("Quest Log's private chat")

    // ---- the recipe is the web's (Quest Log's chat.js, BookMaster's secretChat.ts)
    check("the key is made as Quest Log makes it",
          BMQuestLog.salt == "quest-log-chat-salt-v1" && BMQuestLog.authSalt == "quest-log-auth-v1"
          && BMQuestLog.salt != BMQuestLog.authSalt && BMQuestLog.iterations == 100_000
          && BMQuestLog.keyBytes == 32 && BMQuestLog.ivBytes == 12 && BMQuestLog.tagBytes == 16)
    check("the endpoint is Quest Log's, forwarded on BookMaster's address", BMQuestLog.path == "/quest-log/api/chat")
    check("a message is up to the shared room's length", BMQuestLog.maxLength == 2000
          && BMQuestLog.sendable("  hello  ") == "hello" && BMQuestLog.sendable("   ") == nil
          && BMQuestLog.sendable(String(repeating: "x", count: 2001)) == nil)

    // ---- reading what the endpoint stores
    let wire = """
    [{"id":"m1abc2d","role":"giver","ciphertext":"AAAA","iv":"BBBB","ts":1700000000000},
     {"id":1700000000123,"role":"adventurer","ciphertext":"CCCC","iv":"DDDD","ts":1700000001000},
     {"role":"giver","ciphertext":"x","iv":"y","ts":1},
     {"id":"nocipher","role":"giver","ts":1},
     {"id":"m1abc2d","role":"giver","ciphertext":"AAAA","iv":"BBBB","ts":1700000000000}]
    """.data(using: .utf8)!
    let raws = BMQuestLog.decode(wire)
    check("entries are read, the malformed ones left out and not the room",
          raws.map(\.id) == ["m1abc2d", "1700000000123", "m1abc2d"], "\(raws.map(\.id))")
    check("a numeric id becomes its digits", raws[1].id == "1700000000123" && raws[1].ts == 1_700_000_001_000)
    check("a repeat of an id is shown once", BMQuestLog.once(raws).map(\.id) == ["m1abc2d", "1700000000123"])
    check("an answer that is not a list is an empty room", BMQuestLog.decode(Data("{}".utf8)).isEmpty
          && BMQuestLog.decode(Data("nonsense".utf8)).isEmpty)

    // ---- opening
    let pass: (String, String) -> String? = { cipher, _ in cipher == "AAAA" ? "plain words" : cipher == "CCCC" ? "{\"text\":\"wrapped words\"}" : nil }
    let first = BMQuestLog.open(raws[0], opener: pass)
    check("an entry the key opens is its text", first?.text == "plain words" && first?.failed == false && first?.role == .giver
          && first?.at == 1_700_000_000_000)
    check("a wrapped entry is the text inside", BMQuestLog.open(raws[1], opener: pass)?.text == "wrapped words")
    let locked = BMQuestLog.open(BMQuestLog.Raw(id: "zzzzzz", role: "adventurer", ciphertext: "no", iv: "no", ts: 5), opener: pass)
    check("one this passphrase does not open is a locked line, not a missing one", locked?.failed == true && locked?.text == "🔒")
    check("a role Quest Log does not have is skipped",
          BMQuestLog.open(BMQuestLog.Raw(id: "zzzzzz", role: "wizard", ciphertext: "AAAA", iv: "x", ts: 5), opener: pass) == nil)
    check("unwrapping follows the web's reading of a message",
          BMQuestLog.unwrap("hello") == "hello" && BMQuestLog.unwrap("{\"text\":\"hi\"}") == "hi"
          && BMQuestLog.unwrap("{\"other\":1}") == "" && BMQuestLog.unwrap("[1,2]") == ""
          && BMQuestLog.unwrap("42") == "42" && BMQuestLog.unwrap("\"quoted\"") == "\"quoted\""
          && BMQuestLog.unwrap("null") == "null" && BMQuestLog.unwrap("{\"text\":5}") == "")

    // ---- ids Quest Log accepts
    var generated: Set<String> = []
    for _ in 0 ..< 200 { generated.insert(BMQuestLog.newID()) }
    check("an id is accepted by Quest Log (6–40 of letters, digits, _ and -) and rarely repeats",
          generated.allSatisfy(BMQuestLog.isValidID) && generated.count == 200)
    check("the id's shape is checked", !BMQuestLog.isValidID("short") && !BMQuestLog.isValidID("has space")
          && !BMQuestLog.isValidID(String(repeating: "a", count: 41)) && BMQuestLog.isValidID("m-abc_12"))
    check("an id made with no randomness left is still long enough",
          BMQuestLog.isValidID(BMQuestLog.newID(now: Date(timeIntervalSince1970: 0), randomness: { 0 })))

    // ---- failures
    check("a status is a failure or none",
          BMQuestLog.failure(forStatus: 200) == nil && BMQuestLog.failure(forStatus: 401) == .wrongPassphrase
          && BMQuestLog.failure(forStatus: 403) == .roleTaken && BMQuestLog.failure(forStatus: 429) == .tooManyGuesses
          && BMQuestLog.failure(forStatus: 502) == .server(502))
    check("each is told in words", BMQuestLog.explain(.wrongPassphrase).contains("not the Quest Log passphrase")
          && BMQuestLog.explain(.roleTaken).contains("another device")
          && BMQuestLog.explain(.tooManyGuesses).contains("Too many wrong passphrases")
          && BMQuestLog.explain(.unreachable, sending: true).contains("did not send"))
    check("the other part of the story", BMQuestLog.Role.giver.other == .adventurer && BMQuestLog.Role.adventurer.other == .giver
          && BMQuestLog.Role.allCases.map(\.rawValue) == ["giver", "adventurer"])

    // ---- how far each has read: Quest Log's own receipts
    check("the presence endpoint is beside the chat one", BMQuestLog.heartbeatPath == "/quest-log/api/heartbeat")
    let beats = Data(#"{"now":1700000009000,"giver":{"lastActive":1700000008000,"lastRead":1700000005000,"typing":1700000007000},"adventurer":{"lastActive":1700000001000,"typing":1700000001000}}"#.utf8)
    let presence = BMQuestLog.presence(beats)
    check("how far each has read comes out of the heartbeat, 0 for one who has not",
          presence?.readUpTo[.giver] == 1_700_000_005_000 && presence?.readUpTo[.adventurer] == 0, "\(String(describing: presence))")
    check("typing is timed by Quest Log's clock: what is left of its six seconds, and none once they are up",
          presence?.typingFor[.giver] == 4000 && presence?.typingFor[.adventurer] == 0, "\(String(describing: presence))")
    check("an answer that is not the heartbeat says nothing", BMQuestLog.presence(Data("[]".utf8)) == nil)
    check("an old heartbeat, a bare number, has read nothing and is not typing",
          BMQuestLog.presence(Data(#"{"now":5,"giver":1700000000000}"#.utf8)).map { $0.readUpTo[.giver] == 0 && $0.typingFor[.giver] == 0 } == true)
    check("with no clock to time it by, typing is not claimed",
          BMQuestLog.presence(Data(#"{"giver":{"typing":1700000000000}}"#.utf8))?.typingFor[.giver] == 0)
    check("typing is said within its window, and held over the gap between looks",
          BMQuestLog.typingEvery * 1000 < BMQuestLog.typingWindow
          && BMQuestLog.typingHold + BMQuestLog.typingEvery * 1000 >= Double(BMQuestLog.pollSeconds) * 1000)
    let lastMine = BMQuestLog.Entry(id: "mine1", role: .giver, text: "hi", at: 1_700_000_005_000, failed: false)
    check("your last message is Seen once they have read up to it, Sent before, and nothing while unknown",
          BMQuestLog.seenLabel(lastMine, theirsRead: 1_700_000_005_000) == "Seen"
          && BMQuestLog.seenLabel(lastMine, theirsRead: 1_700_000_004_999) == "Sent"
          && BMQuestLog.seenLabel(lastMine, theirsRead: nil) == nil)
    struct Report: Decodable, Equatable {
        var role: String
        var lastRead: Int64?
        var typing: Bool?
        var elsewhere: Bool
    }
    func said(_ data: Data?) -> (Report?, [String]?) {
        (data.flatMap { try? JSONDecoder().decode(Report.self, from: $0) },
         data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?.keys.sorted())
    }
    let (readSaid, readKeys) = said(BMQuestLog.report(.adventurer, lastRead: 1_700_000_005_000))
    check("a read is reported as the stamp, whole, and from elsewhere — not as being in Quest Log",
          readSaid == Report(role: "adventurer", lastRead: 1_700_000_005_000, typing: nil, elsewhere: true)
          && readKeys == ["elsewhere", "lastRead", "role"], "\(String(describing: readSaid)) \(String(describing: readKeys))")
    let (typingSaid, typingKeys) = said(BMQuestLog.report(.giver, typing: true))
    let (stoppedSaid, _) = said(BMQuestLog.report(.giver, typing: false))
    check("typing, and having stopped, are said the same way, with nothing else",
          typingSaid == Report(role: "giver", lastRead: nil, typing: true, elsewhere: true)
          && stoppedSaid == Report(role: "giver", lastRead: nil, typing: false, elsewhere: true)
          && typingKeys == ["elsewhere", "role", "typing"], "\(String(describing: typingSaid)) \(String(describing: typingKeys))")

    // ---- the thread's layout is the shared room's
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let noon = 1_700_000_000_000.0   // 2023-11-14 22:13 UTC
    let entries = [
        BMQuestLog.Entry(id: "a", role: .adventurer, text: "one", at: noon - 90_000_000, failed: false),
        BMQuestLog.Entry(id: "b", role: .adventurer, text: "two", at: noon - 89_990_000, failed: false),
        BMQuestLog.Entry(id: "c", role: .giver, text: "three", at: noon - 89_900_000, failed: false),
        BMQuestLog.Entry(id: "d", role: .giver, text: "four", at: noon, failed: false),
    ]
    let rows = BMQuestLog.rows(entries, now: Date(timeIntervalSince1970: noon / 1000), calendar: calendar,
                               locale: Locale(identifier: "en_US_POSIX"))
    check("each entry has its row, in order", rows.map(\.id) == ["a", "b", "c", "d"])
    check("a day is labelled where it begins, and a burst by its first and last",
          rows[0].day != nil && rows[1].day == nil && rows[3].day == "Today"
          && rows[0].head && !rows[1].head && rows[1].tail && !rows[0].tail && rows[2].head && rows[2].tail,
          "\(rows.map { "\($0.day ?? "-")/\($0.head)/\($0.tail)" })")
}
