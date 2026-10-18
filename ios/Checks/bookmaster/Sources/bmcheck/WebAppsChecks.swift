import Foundation

// Checks for the in-app browser's rules: where each app opens, which app a page belongs to,
// where a notice goes, and what the browser will and won't show.

@MainActor
func runWebAppsChecks() {
    section("In-app web apps")
    func u(_ s: String) -> URL { URL(string: s)! }

    // ---- where each opens, and which app a page belongs to
    check("each app opens at its front door",
          BMWebApp.bookmaster.start.absoluteString == "https://bookmaster.pages.dev/dashboard"
          && BMWebApp.kindred.start.absoluteString == "https://bookmaster.pages.dev/kindred/today"
          && BMWebApp.questLog.start.absoluteString == "https://bookmaster.pages.dev/quest-log/")
    check("a page belongs to the app whose path it is under",
          BMWebApp.app(for: u("https://bookmaster.pages.dev/kindred/ask")) == .kindred
          && BMWebApp.app(for: u("https://bookmaster.pages.dev/kindred")) == .kindred
          && BMWebApp.app(for: u("https://bookmaster.pages.dev/quest-log/")) == .questLog
          && BMWebApp.app(for: u("https://bookmaster.pages.dev/quest-log")) == .questLog
          && BMWebApp.app(for: u("https://bookmaster.pages.dev/library/abc")) == .bookmaster)
    check("…and a path that only starts with the name is BookMaster's own",
          BMWebApp.app(for: u("https://bookmaster.pages.dev/kindredly")) == .bookmaster
          && BMWebApp.app(for: u("https://bookmaster.pages.dev/quest-logs/x")) == .bookmaster)
    check("every app has a name and a symbol",
          BMWebApp.allCases.count == 3 && BMWebApp.allCases.allSatisfy { !$0.name.isEmpty && !$0.symbol.isEmpty })

    // ---- where a notice goes
    check("a notice's path is the app's own, on the shared host",
          BMWebApp.url(app: .kindred, path: "/today")?.absoluteString == "https://bookmaster.pages.dev/kindred/today"
          && BMWebApp.url(app: .bookmaster, path: "/together")?.absoluteString == "https://bookmaster.pages.dev/together"
          && BMWebApp.url(app: .questLog, path: "/")?.absoluteString == "https://bookmaster.pages.dev/quest-log/")
    check("…with its query kept",
          BMWebApp.url(app: .questLog, path: "/?tab=operations")?.absoluteString == "https://bookmaster.pages.dev/quest-log/?tab=operations",
          BMWebApp.url(app: .questLog, path: "/?tab=operations")?.absoluteString ?? "nil")
    check("a path that is not plain is refused",
          BMWebApp.url(app: .kindred, path: "//evil.example/x") == nil
          && BMWebApp.url(app: .kindred, path: "https://evil.example/") == nil
          && BMWebApp.url(app: .kindred, path: "today") == nil
          && BMWebApp.url(app: .kindred, path: "/a\\b") == nil
          && BMWebApp.url(app: .kindred, path: "/a\nb") == nil
          && BMWebApp.url(app: .kindred, path: "") == nil)
    check("a path can never change the host",
          ["/@evil.example/", "/.evil.example", "/x?@evil.example", "/%2F%2Fevil.example"].allSatisfy {
              BMWebApp.url(app: .bookmaster, path: $0).map { $0.host == "bookmaster.pages.dev" } ?? true
          })
    check("a notice finds its app and address",
          BMWebApp.destination(noticeApp: "kindred", path: "/ask")?.app == .kindred
          && BMWebApp.destination(noticeApp: "quest-log", path: "/")?.url.absoluteString == "https://bookmaster.pages.dev/quest-log/"
          && BMWebApp.destination(noticeApp: "pageturner", path: "/x") == nil
          && BMWebApp.destination(noticeApp: "mystery", path: "/x") == nil
          && BMWebApp.destination(noticeApp: "kindred", path: nil) == nil)

    // ---- what a download is saved as
    check("a download keeps its own name", BMWebPolicy.safeFileName("bookmaster-library-2026-10-18.csv") == "bookmaster-library-2026-10-18.csv")
    check("…without folders", BMWebPolicy.safeFileName("../../etc/passwd") == "passwd" && BMWebPolicy.safeFileName("a/b\\c.csv") == "c.csv")
    check("…or oddities, or an empty name",
          BMWebPolicy.safeFileName("na:me\n.csv") == "name.csv" && BMWebPolicy.safeFileName("") == "download"
          && BMWebPolicy.safeFileName("///") == "download" && BMWebPolicy.safeFileName("...") == "download" && BMWebPolicy.safeFileName("  ") == "download")
    check("…and a sane length", BMWebPolicy.safeFileName(String(repeating: "a", count: 500) + ".csv").count == 100)

    // ---- what the browser will show
    let main = BMWebPolicy.decide
    check("our own host is shown, any path", main(u("https://bookmaster.pages.dev/kindred/today"), true) == .allow
          && main(u("https://BookMaster.Pages.Dev/library"), true) == .allow)
    check("any other site goes to Safari",
          main(u("https://example.com/"), true) == .external
          && main(u("https://bookmaster.pages.dev.evil.example/"), true) == .external
          && main(u("https://evil.example/bookmaster.pages.dev"), true) == .external
          && main(u("https://quest-log-app.pages.dev/"), true) == .external)
    check("…but a frame inside one of our pages is its own business", main(u("https://example.com/embed"), false) == .allow)
    check("plain http is never shown", main(u("http://bookmaster.pages.dev/"), true) == .external && main(u("http://bookmaster.pages.dev/"), false) == .block)
    check("mail and phone links go to iOS", main(u("mailto:a@b.example"), true) == .external && main(u("tel:+15551234"), true) == .external)
    check("a page cannot steer the app, or reach the disk",
          main(u("pageturner://link?code=abcdef0123456789"), true) == .block
          && main(u("file:///etc/passwd"), true) == .block
          && main(u("javascript:alert(1)"), true) == .block
          && main(u("itms-apps://apps.apple.com/app/x"), true) == .block)
    check("a data: page is not a page, though a frame may carry one",
          main(u("data:text/html,hi"), true) == .block && main(u("data:text/html,hi"), false) == .allow)
    check("plumbing is let through", main(u("about:blank"), true) == .allow && main(u("blob:https://bookmaster.pages.dev/1234"), true) == .allow)
    check("only a secure page is offered to Safari",
          BMWebPolicy.shareable(u("https://bookmaster.pages.dev/library"))?.host == "bookmaster.pages.dev"
          && BMWebPolicy.shareable(u("http://bookmaster.pages.dev/")) == nil
          && BMWebPolicy.shareable(u("about:blank")) == nil && BMWebPolicy.shareable(nil) == nil)
}
