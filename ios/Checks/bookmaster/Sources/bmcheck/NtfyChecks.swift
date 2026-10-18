import Foundation

// Checks for instant notifications and the deep link a tapped one carries.

@MainActor
func runNtfyChecks() {
    section("Instant notifications (ntfy)")
    func u(_ s: String) -> URL { URL(string: s)! }

    // ---- what BookMaster says
    let on = try? JSONDecoder().decode(
        BMNtfyStatus.self,
        from: Data(#"{"available":true,"server":"https://ntfy.sh","topic":"bm-abc","link":"pageturner","preview":false}"#.utf8))
    check("a status decodes: on, tapping opens Pageturner", on?.isOn == true && on?.opensPageturner == true && on?.preview == false, "\(String(describing: on))")
    let off = try? JSONDecoder().decode(
        BMNtfyStatus.self, from: Data(#"{"available":true,"server":"https://ntfy.sh","topic":null,"link":null,"preview":false}"#.utf8))
    check("…and off, with no topic", off?.isOn == false && off?.opensPageturner == false)
    let unavailable = try? JSONDecoder().decode(
        BMNtfyStatus.self, from: Data(#"{"available":false,"server":null,"topic":null,"link":null,"preview":false}"#.utf8))
    check("…and unavailable, when BookMaster has no server for it", unavailable?.available == false && unavailable?.server == nil)
    check("the server reads as a name to type", BMNtfy.serverLabel("https://ntfy.sh") == "ntfy.sh"
          && BMNtfy.serverLabel("https://ntfy.example.org") == "ntfy.example.org" && BMNtfy.serverLabel(nil) == "ntfy.sh"
          && BMNtfy.serverLabel("not a url") == "ntfy.sh")

    // ---- asking again
    let now = Date(timeIntervalSince1970: 1_792_335_600)
    let t = now.timeIntervalSince1970
    check("never asked is asked now", BMNtfy.shouldRecheck(lastChecked: 0, now: now))
    check("not asked again within six hours", !BMNtfy.shouldRecheck(lastChecked: t - 3600, now: now))
    check("asked again after them", BMNtfy.shouldRecheck(lastChecked: t - 7 * 3600, now: now))
    check("a clock that went backwards is not trusted", BMNtfy.shouldRecheck(lastChecked: t + 86_400, now: now))

    // ---- what a tap opens
    let chat = BMDeepLink.parse(u("pageturner://open?app=bookmaster&path=%2Fchat"))
    check("the chat opens the chat", chat == .chat, "\(String(describing: chat))")
    check("…whatever follows its path", BMDeepLink.parse(u("pageturner://open?app=bookmaster&path=%2Fchat%3Fx%3D1")) == .chat)
    if case let .web(app, url)? = BMDeepLink.parse(u("pageturner://open?app=kindred&path=%2Ftoday")) {
        check("a Kindred notice opens Kindred at its page", app == .kindred && url.absoluteString == "https://bookmaster.pages.dev/kindred/today", url.absoluteString)
    } else { check("a Kindred notice opens Kindred at its page", false) }
    if case let .web(app, url)? = BMDeepLink.parse(u("pageturner://open?app=quest-log&path=%2Fquest-log")) {
        check("a Quest Log notice opens Quest Log, once under /quest-log", app == .questLog && url.absoluteString == "https://bookmaster.pages.dev/quest-log", url.absoluteString)
    } else { check("a Quest Log notice opens Quest Log, once under /quest-log", false) }
    if case let .web(app, _)? = BMDeepLink.parse(u("pageturner://open?app=bookmaster&path=%2Ftogether")) {
        check("a BookMaster notice opens BookMaster", app == .bookmaster)
    } else { check("a BookMaster notice opens BookMaster", false) }

    // ---- what a tap may not open: anyone can make this address
    check("nothing else is an open request",
          BMDeepLink.parse(u("pageturner://link?code=abcdef0123456789")) == nil
          && BMDeepLink.parse(u("https://bookmaster.pages.dev/chat")) == nil
          && BMDeepLink.parse(u("otherapp://open?app=kindred&path=%2Ftoday")) == nil
          && BMDeepLink.parse(u("pageturner://open")) == nil
          && BMDeepLink.parse(u("pageturner://open?app=kindred")) == nil
          && BMDeepLink.parse(u("pageturner://open?path=%2Ftoday")) == nil)
    check("…not another host, an unknown app, or an odd path",
          BMDeepLink.parse(u("pageturner://open?app=kindred&path=https%3A%2F%2Fevil.example%2F")) == nil
          && BMDeepLink.parse(u("pageturner://open?app=kindred&path=%2F%2Fevil.example")) == nil
          && BMDeepLink.parse(u("pageturner://open?app=pageturner&path=%2Fx")) == nil
          && BMDeepLink.parse(u("pageturner://open?app=mystery&path=%2Fx")) == nil)
    check("a hostile path stays on our host or is refused",
          ["%2F%40evil.example%2F", "%2F.evil.example", "%2F%5C%5Cevil.example"].allSatisfy { path in
              if case let .web(_, url)? = BMDeepLink.parse(u("pageturner://open?app=bookmaster&path=\(path)")) {
                  return url.host == "bookmaster.pages.dev"
              }
              return true
          })
}
