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
}
