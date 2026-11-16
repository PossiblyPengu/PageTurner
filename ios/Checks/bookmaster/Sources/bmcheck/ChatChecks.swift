import Foundation

// Checks for what is left of the chat in the app: whether the suite's feed says a message waits, and the floating
// button. (The chats themselves are BookMaster's page, shown in a web view; their rules are checked there.)

@MainActor
func runChatChecks() {
    section("Shared chat")

    // ---- the unread notice
    let chatNotice = BMNotice(id: "bookmaster:chat:42", app: "bookmaster", text: "Kristen: hi")
    let other = BMNotice(id: "bookmaster:suggestion:7", app: "bookmaster", text: "A book")
    check("the feed's chat notice is found among the others",
          BMChat.unreadNotice([other, chatNotice])?.id == "bookmaster:chat:42" && BMChat.unreadNotice([other]) == nil
          && BMChat.unreadNotice([]) == nil)

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
