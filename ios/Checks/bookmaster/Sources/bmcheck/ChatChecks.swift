import Foundation

// Checks for the shared chat's logic: what may be sent, how pages fold into what is shown, how a
// run of messages is laid out, and what "Seen" says.

private func msg(_ id: Int, _ from: String, _ body: String = "x", app: String = "bookmaster", at: Double) -> BMChatMessage {
    BMChatMessage(id: id, userId: from, name: from == "u1" ? "Andrew" : "Kristen", body: body, app: app, at: at)
}

@MainActor
func runChatChecks() {
    section("Shared chat")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let en = Locale(identifier: "en_US_POSIX")
    // Sun 18 Oct 2026, 15:00 UTC
    let now = Date(timeIntervalSince1970: 1_792_335_600)
    let ms = { (d: Date) in d.timeIntervalSince1970 * 1000 }
    let min = 60_000.0

    // ---- decoding what BookMaster sends
    let json = """
    {"messages":[{"id":7,"user_id":"u1","name":"Andrew","body":"hi","app":"kindred","at":1792335000000}],
     "me":{"id":"u1","display_name":"Andrew"},"partner":{"id":"u2","display_name":"Kristen"},
     "read":{"mine":7,"theirs":3},"unread":0,"complete":false,"questLogRole":"giver"}
    """
    let room = try? JSONDecoder().decode(BMChatRoom.self, from: Data(json.utf8))
    check("a room decodes, ignoring what the app has no use for",
          room?.messages.first?.id == 7 && room?.messages.first?.userId == "u1" && room?.messages.first?.app == "kindred"
          && room?.me.displayName == "Andrew" && room?.partner?.displayName == "Kristen"
          && room?.read.theirs == 3 && room?.complete == false, "\(String(describing: room))")
    check("…a message's time is milliseconds", room?.messages.first?.date == Date(timeIntervalSince1970: 1_792_335_000))
    let solo = try? JSONDecoder().decode(
        BMChatRoom.self,
        from: Data(#"{"messages":[],"me":{"id":"u1","display_name":"A"},"partner":null,"read":{"mine":0,"theirs":0},"unread":0,"complete":true}"#.utf8))
    check("a room with nobody else in it decodes", solo != nil && solo?.partner == nil)
    let sent = try? JSONDecoder().decode(
        BMChatSent.self, from: Data(#"{"message":{"id":9,"user_id":"u1","name":"A","body":"b","app":"pageturner","at":1}}"#.utf8))
    check("a send's reply decodes", sent?.message.id == 9 && sent?.message.app == "pageturner")

    // ---- what may be sent
    check("a draft is trimmed", BMChat.sendable("  hello there \n") == "hello there")
    check("a blank draft is not sent", BMChat.sendable("   \n ") == nil && BMChat.sendable("") == nil)
    check("the limit is the server's: 2000 goes, 2001 does not",
          BMChat.sendable(String(repeating: "a", count: 2000)) != nil && BMChat.sendable(String(repeating: "a", count: 2001)) == nil)
    check("…counted as the server counts, in UTF-16 units: 1000 emoji go, 1001 do not",
          BMChat.sendable(String(repeating: "😀", count: 1000)) != nil && BMChat.sendable(String(repeating: "😀", count: 1001)) == nil)
    check("…and a family emoji is eleven", BMChat.sendable(String(repeating: "👨‍👩‍👧‍👦", count: 181)) != nil
          && BMChat.sendable(String(repeating: "👨‍👩‍👧‍👦", count: 182)) == nil)
    check("too long is not the same as blank", BMChat.isTooLong(String(repeating: "a", count: 2001)) && !BMChat.isTooLong("") && !BMChat.isTooLong("   "))

    // ---- folding pages in
    let a = msg(1, "u1", at: 0), b = msg(2, "u2", at: 0), c = msg(3, "u1", at: 0), d = msg(4, "u2", at: 0)
    check("merge keeps id order and each message once",
          BMChat.merge([c, a], [b, c, d]).map(\.id) == [1, 2, 3, 4])
    var edited = c
    edited.body = "edited"
    check("…and the incoming copy wins", BMChat.merge([c], [edited]).first?.body == "edited")
    check("refreshing the newest page keeps older messages already loaded",
          BMChat.replacingNewest([a, b, c, d], with: [c, d]).map(\.id) == [1, 2, 3, 4])
    check("…and drops what the other reader took back",
          BMChat.replacingNewest([a, b, c, d], with: [b, d]).map(\.id) == [1, 2, 4])
    check("…and picks up what is new", BMChat.replacingNewest([a, b], with: [b, c, d]).map(\.id) == [1, 2, 3, 4])
    check("an empty page is an empty room", BMChat.replacingNewest([a, b], with: []).isEmpty)
    // more than a page arrived while away: the old run is no longer joined to the new page
    let far = (100..<103).map { msg($0, "u1", at: 0) }
    check("a full page that reaches back to nothing held replaces it, so no hole is left",
          BMChat.replacingNewest([a, b], with: far, pageSize: 3).map(\.id) == [100, 101, 102])
    check("…but a page that is not full, or that overlaps, is joined as usual",
          BMChat.replacingNewest([a, b], with: Array(far.prefix(2)), pageSize: 3).map(\.id) == [1, 2, 100, 101]
          && BMChat.replacingNewest([a, b, c], with: [c, d, msg(5, "u1", at: 0)], pageSize: 3).map(\.id) == [1, 2, 3, 4, 5])

    // ---- what to say when it fails
    check("a rate limit says what the server said", BMChat.explain(BMError.server(429, "Slow down a little — too many messages at once.")) == "Slow down a little — too many messages at once.")
    check("a broken link says to link again, not 'Unknown reader'",
          BMChat.explain(BMError.server(404, "Unknown reader")).contains("Link it again"))
    check("a server error without words is still a sentence", BMChat.explain(BMError.server(500, nil)) == "BookMaster answered 500."
          && BMChat.explain(BMError.server(429, nil)).hasPrefix("Slow down"))
    check("no connection says so", BMChat.explain(BMError.notLinked).hasPrefix("Couldn’t reach") && BMChat.explain(URLError(.notConnectedToInternet)).hasPrefix("Couldn’t reach"))

    // ---- seen
    check("seen once they have read it", BMChat.seenLabel(lastMineId: 5, theirsRead: 5, hasPartner: true) == "Seen"
          && BMChat.seenLabel(lastMineId: 5, theirsRead: 9, hasPartner: true) == "Seen")
    check("sent until then", BMChat.seenLabel(lastMineId: 5, theirsRead: 4, hasPartner: true) == "Sent")
    check("nothing with nobody to read it, or nothing of yours",
          BMChat.seenLabel(lastMineId: 5, theirsRead: 9, hasPartner: false) == nil
          && BMChat.seenLabel(lastMineId: nil, theirsRead: 9, hasPartner: true) == nil)

    // ---- where it was written, and the unread notice
    check("a message from another app says which", BMChat.via("kindred") == "Kindred" && BMChat.via("bookmaster") == "BookMaster")
    check("…but not one from here", BMChat.via("pageturner") == nil)
    check("an unknown app says nothing rather than something odd", BMChat.via("mystery") == nil)
    let chatNotice = BMNotice(id: "bookmaster:chat:42", app: "bookmaster", text: "Kristen: hi")
    let other = BMNotice(id: "bookmaster:suggestion:7", app: "bookmaster", text: "A book")
    check("the feed's chat notice is found among the others",
          BMChat.unreadNotice([other, chatNotice])?.id == "bookmaster:chat:42" && BMChat.unreadNotice([other]) == nil
          && BMChat.unreadNotice([]) == nil)

    // ---- day labels
    let hour = 60.0
    let dayMinutes = 24.0 * hour
    let sinceMidnight = 15.0 * hour // `now` is 15:00
    func label(_ minutesAgo: Double) -> String {
        BMChat.dayLabel(now.addingTimeInterval(-minutesAgo * 60), now: now, calendar: cal, locale: en)
    }
    let justAfterMidnight = label(sinceMidnight - 1)
    let justBeforeMidnight = label(sinceMidnight + 1)
    let yesterdayNoon = label(sinceMidnight + 12 * hour)
    check("today and yesterday are named", label(5) == "Today" && yesterdayNoon == "Yesterday", "\(label(5)) \(yesterdayNoon)")
    check("midnight is the boundary, not 24 hours", justAfterMidnight == "Today" && justBeforeMidnight == "Yesterday",
          "\(justAfterMidnight) \(justBeforeMidnight)")
    let threeDays = label(3 * dayMinutes)
    check("a weekday inside a week", threeDays == "Thursday", threeDays)
    let fortyDays = label(40 * dayMinutes)
    let fourHundred = label(400 * dayMinutes)
    check("a date beyond it, and a year only when it is not this one",
          fortyDays == "Sep 8" && fourHundred == "Sep 13, 2025", "\(fortyDays) | \(fourHundred)")

    // ---- layout
    let t0 = ms(now) - 3 * 60 * min // 12:00 today
    let day = BMChat.rows(
        [msg(1, "u1", at: t0), msg(2, "u1", at: t0 + 2 * min), msg(3, "u2", at: t0 + 3 * min), msg(4, "u2", at: t0 + 3 * min + 6 * min)],
        now: now, calendar: cal, locale: en)
    check("a burst is headed on its first line and tailed on its last",
          day.map(\.head) == [true, false, true, true] && day.map(\.tail) == [false, true, true, true],
          "\(day.map(\.head)) \(day.map(\.tail))")
    check("the first line of the day carries the day, the rest do not",
          day.map(\.day) == ["Today", nil, nil, nil], "\(day.map(\.day))")
    let overnight = BMChat.rows(
        [msg(1, "u1", at: ms(now) - 15 * 60 * min - 1 * min), msg(2, "u1", at: ms(now) - 15 * 60 * min + 1 * min)],
        now: now, calendar: cal, locale: en)
    check("midnight breaks a burst and starts a day",
          overnight.map(\.head) == [true, true] && overnight.map(\.day) == ["Yesterday", "Today"], "\(overnight.map(\.day))")
    check("an empty room has no rows", BMChat.rows([], now: now, calendar: cal, locale: en).isEmpty)
    check("a clock time reads in the reader's locale",
          BMChat.clock(Date(timeIntervalSince1970: 1_792_335_600 - 3 * 3600), calendar: cal, locale: en).hasPrefix("12:00"))

    // ---- the unread dot, and the floating button
    let waiting = BMNotice(id: "bookmaster:chat:42", app: "bookmaster", text: "Kristen: hi")
    let newer = BMNotice(id: "bookmaster:chat:43", app: "bookmaster", text: "Kristen: again")
    check("an unread message shows until it has been opened",
          BMChat.unread([waiting], seen: nil)?.id == "bookmaster:chat:42" && BMChat.unread([waiting], seen: "bookmaster:chat:42") == nil
          && BMChat.unread([], seen: nil) == nil)
    check("…and a newer one brings the dot back", BMChat.unread([newer], seen: "bookmaster:chat:42")?.id == "bookmaster:chat:43")

    check("the button shows for a linked reader who has it on",
          BMChatButton.isShown(linked: true, enabled: true, readerOpen: false, hiders: 0))
    check("…not unlinked, not switched off, not over the reader, not over the chat or a web page",
          !BMChatButton.isShown(linked: false, enabled: true, readerOpen: false, hiders: 0)
          && !BMChatButton.isShown(linked: true, enabled: false, readerOpen: false, hiders: 0)
          && !BMChatButton.isShown(linked: true, enabled: true, readerOpen: true, hiders: 0)
          && !BMChatButton.isShown(linked: true, enabled: true, readerOpen: false, hiders: 1))

    typealias Spot = BMChatButton.Spot
    check("a spot is kept as text and read back",
          Spot(stored: Spot.standard.stored) == Spot.standard && Spot(stored: "l:250") == Spot(trailing: false, y: 0.25)
          && Spot(trailing: true, y: 0.3333).stored == "t:333")
    check("…and anything else is refused",
          Spot(stored: "") == nil && Spot(stored: "t") == nil && Spot(stored: "x:100") == nil && Spot(stored: "t:abc") == nil
          && Spot(stored: "t:1001") == nil && Spot(stored: "t:-1") == nil && Spot(stored: "t:1:2") == nil)
    check("a height outside the band is held to it",
          Spot(trailing: true, y: -3).y == 0 && Spot(trailing: true, y: 7).y == 1 && Spot(trailing: true, y: .nan).y == Spot.standardY
          && Spot.standard.flipped == Spot(trailing: false, y: Spot.standardY))
    // a 400-wide screen whose free band runs 100…700, a 50-point button 10 from the edge
    let rest = Spot(trailing: true, y: 0.5).center(width: 400, top: 100, bottom: 700, size: 50, margin: 10)
    let high = Spot(trailing: false, y: 0).center(width: 400, top: 100, bottom: 700, size: 50, margin: 10)
    let low = Spot(trailing: false, y: 1).center(width: 400, top: 100, bottom: 700, size: 50, margin: 10)
    check("it rests against its edge, wholly inside the band",
          rest.x == 365 && rest.y == 400 && high.x == 35 && high.y == 125 && low.y == 675, "\(rest) \(high) \(low)")
    let landed = Spot.dropped(x: 120, y: 125, width: 400, top: 100, bottom: 700, size: 50)
    let landedLow = Spot.dropped(x: 300, y: 900, width: 400, top: 100, bottom: 700, size: 50)
    check("let go, it goes to the nearer edge and the height it was left at, held inside the band",
          landed == Spot(trailing: false, y: 0) && landedLow == Spot(trailing: true, y: 1), "\(landed) \(landedLow)")
    // ---- whose dot it is
    let mixed = [BMNotice(id: "quest-log:1", app: "quest-log", text: "Something new"), BMNotice(id: "k:1", app: "kindred", text: "A question")]
    check("Quest Log's dots are told apart from the rest",
          BMSuite.dotTone(forApp: "quest-log") == .questLog && BMSuite.dotTone(forApp: "kindred") == .regular
          && BMSuite.dotTone(forApp: "bookmaster") == .regular && BMSuite.dotTone(forApp: "pageturner") == .regular
          && BMSuite.dotTone(forApp: "") == .regular)
    check("a count is Quest Log's only when nothing else waits",
          BMSuite.dotTone(forNotices: [mixed[0]]) == .questLog && BMSuite.dotTone(forNotices: mixed) == .regular
          && BMSuite.dotTone(forNotices: [mixed[1]]) == .regular && BMSuite.dotTone(forNotices: []) == .regular)
    check("a band with no room still places it", Spot.dropped(x: 10, y: 10, width: 400, top: 700, bottom: 100, size: 50).y == Spot.standardY)
}
