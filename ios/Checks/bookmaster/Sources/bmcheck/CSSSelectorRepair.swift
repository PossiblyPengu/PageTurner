import Foundation

/// Readium's content iterator names the element each utterance and search hit came from with a CSS selector it
/// writes itself — `#id`, `div.cls > p:nth-child(3)` — escaping punctuation in a name but not a digit at its start,
/// and `#1abc` (Calibre gives every body an id like that) is not a selector: `querySelector` throws, so nothing is
/// anchored, painted or scrolled to. CSS spells a leading digit as a hex escape (`#\31 abc`); this writes it that way
/// and leaves every other selector as it was. The selector matters: it is the root the page's text anchor searches
/// in, and without one a sentence or word is looked for in the whole chapter by fuzzy match — "Littles crawling" found
/// as "Littles wagging" twenty screens away, and the page follows the voice there.
enum CSSSelectorRepair {
    static func repaired(_ selector: String) -> String {
        let chars = Array(selector)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            out.append(c)
            i += 1
            // the start of an id or class name, not an escaped "#" or "." inside one
            guard c == "#" || c == ".", i < 2 || chars[i - 2] != "\\" else { continue }
            if i < chars.count, chars[i] == "-" {
                out.append("-")
                i += 1
            }
            if i < chars.count, chars[i].isASCII, let digit = chars[i].wholeNumberValue {
                out += "\\3\(digit) "
                i += 1
            }
        }
        return out
    }
}
