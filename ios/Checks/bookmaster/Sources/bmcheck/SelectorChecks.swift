import Foundation

func runSelectorChecks() {
    section("Locator CSS selectors the page can parse")
    let fix = CSSSelectorRepair.repaired
    check("an id starting with a digit is hex-escaped", fix("#1abc") == "#\\31 abc", fix("#1abc"))
    check("Calibre's body id, with the path below it",
          fix("#2b3c > div.calibre1 > p:nth-child(4)") == "#\\32 b3c > div.calibre1 > p:nth-child(4)",
          fix("#2b3c > div.calibre1 > p:nth-child(4)"))
    check("a class starting with a digit too", fix("div.3col > p") == "div.\\33 col > p", fix("div.3col > p"))
    check("a hyphen then a digit cannot start a name either", fix("#-7x") == "#-\\37 x", fix("#-7x"))
    check("a name starting with a letter is left alone", fix("#calibre_link-12 > p:nth-child(3)") == "#calibre_link-12 > p:nth-child(3)")
    check("nth-child's own digits are not names", fix("body > p:nth-child(12)") == "body > p:nth-child(12)")
    check("an escaped dot inside an id is not a class", fix("#a\\.5x") == "#a\\.5x", fix("#a\\.5x"))
    check("an escaped hash inside an id is not an id", fix("#a\\#9") == "#a\\#9", fix("#a\\#9"))
    check("a page-made selector that is already escaped stays", fix("#\\31 abc > p") == "#\\31 abc > p")
    check("an id of one digit", fix("#7") == "#\\37 ")
    check("a lone hash is left as it is", fix("#") == "#")
    check("a lone hyphen after a hash is left as it is", fix("#- > p") == "#- > p")
    check("a non-ASCII digit is not escaped", fix("#٣x") == "#٣x")
    check("empty in, empty out", fix("") == "")
    // nothing but the first character of a name is ever touched
    var rng = SystemRandomNumberGenerator()
    let alphabet = Array("#.\\-> :()abz019_")
    var untouched = true
    for _ in 0 ..< 20000 {
        let s = String((0 ..< Int.random(in: 0 ..< 12, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
        let out = fix(s)
        // what comes out, with the escapes undone, is what went in
        let undone = out.replacingOccurrences(of: "\\\\3([0-9]) ", with: "$1", options: .regularExpression)
        if undone != s || fix(out) != out { untouched = false; print("    repaired \(s.debugDescription) → \(out.debugDescription)"); break }
    }
    check("random selectors: the repair only rewrites, idempotently, and is undone by unescaping", untouched)
}
