import Foundation

/// The BookMaster tab's one menu of pages (`BMWebNav`): each page once, and which page an address is on.
func runBMWebNavChecks() {
    section("BookMaster tab: one menu of pages")
    let paths = BMWebNav.all.map(\.path)
    check("every page once", Set(paths).count == paths.count && BMWebNav.all.count == 8, paths.joined(separator: " "))
    check("the chat is not a page of the tab", !BMWebNav.all.contains(.tab(.chat)))
    check("an address is on its page", BMWebNav.at(path: "/library") == .tab(.shelf) && BMWebNav.at(path: "/progress/") == .tab(.stats)
          && BMWebNav.at(path: "/dashboard") == .place(.today))
    check("…and on the page it lies under", BMWebNav.at(path: "/library/abc123") == .tab(.shelf)
          && BMWebNav.at(path: "/together/suggestions") == .tab(.together))
    check("not on one whose name it only starts with", BMWebNav.at(path: "/librarything") == nil && BMWebNav.at(path: "/") == nil)
    let host = "https://\(BMLinkURL.bookMasterHost)"
    check("a notice for Together goes to Together's own page",
          BMWebNav.tab(for: URL(string: "\(host)/together?x=1")!, otherwise: .shelf) == .together)
    check("…one for another page to the page on screen",
          BMWebNav.tab(for: URL(string: "\(host)/wrapped")!, otherwise: .stats) == .stats)
    let asked = BMWebNav.embedded(URL(string: "\(host)/series?sort=new")!)
    check("asked to be drawn alone, keeping what it asked", asked.absoluteString == "\(host)/series?sort=new&in=pageturner", asked.absoluteString)
    let already = URL(string: "\(host)/progress?in=pageturner")!
    check("…once", BMWebNav.embedded(already) == already)
}
