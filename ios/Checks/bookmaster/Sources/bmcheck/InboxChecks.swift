import Foundation

// Checks for Pageturner's own notifications: the inbox that keeps what the reader has been told, where
// each item leads, and the rules for holding the app awake in the background.

@MainActor
func runInboxChecks() {
    section("In-app notifications")
    let nudge = BMNudge(id: "n1", note: "You would love it", fromName: "Sam", title: "Piranesi", author: "Susanna Clarke")
    let chat = BMNotice(id: "bookmaster:chat:42", app: "bookmaster", text: "Sam: how is it?", path: "/chat")
    let quest = BMNotice(id: "quest-log:1", app: "quest-log", text: "Something new for you", path: "/quest-log")
    let kindred = BMNotice(id: "kindred:ask:a1", app: "kindred", text: "Sam asked you a question", path: "/ask")
    let t0 = 1_000_000.0

    // ---- what is waiting, as items
    let items = BMInbox.items(nudges: [nudge], notices: [chat, quest], now: t0)
    check("a suggestion and the notices become items, unread, worded like their notifications",
          items.map(\.id) == ["nudge:n1", "notice:bookmaster:chat:42", "notice:quest-log:1"]
          && items[0].title == "Sam suggested a book" && items[0].body == "Piranesi by Susanna Clarke — “You would love it”"
          && items[1].title == "BookMaster" && items[1].body == "Sam: how is it?"
          && items[2].title == "Quest Log" && items.allSatisfy { !$0.read && $0.at == t0 }, "\(items.map(\.title))")

    // ---- keeping the history
    var held = BMInbox.merge([], with: items)
    check("what is waiting is held, newest first, once each", held.count == 3 && BMInbox.unreadCount(held) == 3)
    held = BMInbox.markingRead(held, ids: ["nudge:n1"])
    check("reading one leaves the others unread", BMInbox.unreadCount(held) == 2 && held.first { $0.id == "nudge:n1" }?.read == true)
    // later: the chat message changed, the quest notice went away, a Kindred notice came
    let later = BMInbox.items(nudges: [nudge], notices: [BMNotice(id: "bookmaster:chat:42", app: "bookmaster", text: "Sam: hello?", path: "/chat"), kindred], now: t0 + 600)
    let merged = BMInbox.merge(held, with: later)
    check("an item that has gone from the feed stays in the history", merged.contains { $0.id == "notice:quest-log:1" })
    check("…a new one is added unread, at the time it was first seen",
          merged.first { $0.id == "notice:kindred:ask:a1" }.map { !$0.read && $0.at == t0 + 600 } == true)
    check("…one held keeps its time and whether it was read, and its words are brought up to date",
          merged.first { $0.id == "nudge:n1" }.map { $0.read && $0.at == t0 } == true
          && merged.first { $0.id == "notice:bookmaster:chat:42" }?.body == "Sam: hello?")
    check("the newest comes first", merged.first?.id == "notice:kindred:ask:a1", "\(merged.map(\.id))")
    check("everything can be marked read at once", BMInbox.unreadCount(BMInbox.markingRead(merged)) == 0)
    check("one can be taken out", BMInbox.removing(merged, id: "nudge:n1").count == merged.count - 1 && !BMInbox.removing(merged, id: "nudge:n1").contains { $0.id == "nudge:n1" })
    let many = (0 ..< 150).map { BMInboxItem(id: "notice:\($0)", app: "kindred", title: "t", body: "b", path: nil, at: Double($0), read: false) }
    let capped = BMInbox.merge([], with: many)
    check("no more than a hundred are kept, the newest", capped.count == BMInbox.keep && capped.first?.id == "notice:149" && capped.last?.id == "notice:50")
    let twice = BMInboxItem(id: "x", app: "kindred", title: "t", body: "b", path: nil, at: 1, read: false)
    check("a damaged history with an id twice does not stop it", BMInbox.merge([twice, twice], with: []).count == 1)

    // ---- where an item leads
    check("a suggestion goes to Together", BMInbox.destination(for: items[0]) == .together)
    check("a chat message goes to the chat", BMInbox.destination(for: items[1]) == .chat)
    if case let .web(app, url) = BMInbox.destination(for: items[2]) {
        check("a Quest Log notice opens Quest Log, once under /quest-log", app == .questLog && url.absoluteString == "https://bookmaster.pages.dev/quest-log", url.absoluteString)
    } else { check("a Quest Log notice opens Quest Log", false) }
    if case let .web(app, url) = BMInbox.destination(for: BMInbox.items(nudges: [], notices: [kindred], now: t0)[0]) {
        check("a Kindred notice opens Kindred at its page", app == .kindred && url.absoluteString == "https://bookmaster.pages.dev/kindred/ask", url.absoluteString)
    } else { check("a Kindred notice opens Kindred", false) }
    let odd = BMInboxItem(id: "notice:x", app: "kindred", title: "t", body: "b", path: "https://evil.example/", at: 1, read: false)
    check("an address that is not a page of ours leads nowhere but Together", BMInbox.destination(for: odd) == .together)

    // ---- when
    check("how long ago reads plainly",
          BMInbox.ago(100, now: 130) == "just now" && BMInbox.ago(100, now: 100 + 5 * 60) == "5 min ago"
          && BMInbox.ago(100, now: 100 + 3 * 3600) == "3 h ago" && BMInbox.ago(100, now: 100 + 30 * 3600) == "yesterday"
          && BMInbox.ago(100, now: 100 + 4 * 86_400) == "4 days ago" && BMInbox.ago(100, now: 50) == "just now")

    // ---- staying connected in the background
    check("it runs only when asked for, linked, and in the background",
          BMKeepAlive.shouldRun(enabled: true, linked: true, background: true)
          && !BMKeepAlive.shouldRun(enabled: false, linked: true, background: true)
          && !BMKeepAlive.shouldRun(enabled: true, linked: false, background: true)
          && !BMKeepAlive.shouldRun(enabled: true, linked: true, background: false))
    check("it looks every half minute, and less often in Low Power Mode",
          BMKeepAlive.pollInterval(lowPower: false) == 30 && BMKeepAlive.pollInterval(lowPower: true) == 90)
    let wav = BMKeepAlive.silence()
    let header = String(decoding: wav.prefix(4), as: UTF8.self) + String(decoding: wav[8 ..< 12], as: UTF8.self)
        + String(decoding: wav[12 ..< 16], as: UTF8.self) + String(decoding: wav[36 ..< 40], as: UTF8.self)
    func le32(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 | Int(wav[at + 2]) << 16 | Int(wav[at + 3]) << 24 }
    check("the silence is a whole WAV file", header == "RIFFWAVEfmt data" && wav.count == 44 + 16_000
          && le32(4) == wav.count - 8 && le32(40) == 16_000 && le32(24) == 8000 && wav[44...].allSatisfy { $0 == 0 }, header)
    check("…of any length", BMKeepAlive.silence(seconds: 2, sampleRate: 16_000).count == 44 + 64_000 && BMKeepAlive.silence(seconds: 0).count == 44 + 16_000)
}
