import Foundation

/// The hands-free turner's pace (`HandsFreePace`): how much of a book a page is, and how long it stays up.
func runHandsFreeChecks() {
    section("Hands-free page turning")
    var steps: [Double] = []
    for step in [0.0011, 0.0010, -0.0010, 0.3, 0.0012, 0.0004] { steps = HandsFreePace.noting(step, in: steps) }
    check("a step back and a jump are not pages", steps == [0.0011, 0.0010, 0.0012, 0.0004], "\(steps)")
    check("only the latest are kept", HandsFreePace.noting(0.001, in: Array(repeating: 0.002, count: 12)).count == 12
          && HandsFreePace.noting(0.001, in: Array(repeating: 0.002, count: 12)).last == 0.001)
    check("a page is the middle step: the short last page of a chapter counts for little",
          abs((HandsFreePace.pageShare(steps: steps) ?? 0) - 0.00105) < 1e-9, "\(HandsFreePace.pageShare(steps: steps) ?? -1)")
    check("one step is not enough to go on", HandsFreePace.pageShare(steps: [0.001]) == nil)
    // 900 pages, eight hours a book: 32 s a page
    check("a page's time is its share of the book's", HandsFreePace.seconds(pageShare: 1.0 / 900, minutesPerBook: 480) == 32,
          "\(HandsFreePace.seconds(pageShare: 1.0 / 900, minutesPerBook: 480) ?? -1)")
    check("no pace, no page time", HandsFreePace.seconds(pageShare: nil, minutesPerBook: 480) == nil
          && HandsFreePace.seconds(pageShare: 0.001, minutesPerBook: nil) == nil)
    check("never too quick to read, nor left up for ever",
          HandsFreePace.seconds(pageShare: 0.00001, minutesPerBook: 60) == HandsFreePace.shortest
          && HandsFreePace.seconds(pageShare: 0.04, minutesPerBook: 3000) == HandsFreePace.longest)
    check("quicker and slower by a tenth", HandsFreePace.adjusted(40, quicker: true) == 36 && HandsFreePace.adjusted(40, quicker: false) == 44)
    check("by a second at least", HandsFreePace.adjusted(6, quicker: false) == 7)
    check("and not past the ends", HandsFreePace.adjusted(5, quicker: true) == 5 && HandsFreePace.adjusted(300, quicker: false) == 300)
    check("said plainly", HandsFreePace.label(32) == "32 s a page" && HandsFreePace.label(70) == "1 min 10 s a page"
          && HandsFreePace.label(120) == "2 min a page")
}
