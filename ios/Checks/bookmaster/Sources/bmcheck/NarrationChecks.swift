import Foundation

func runNarrationChecks() {
    section("The voice holds the place while the page catches up")
    check("nothing narrated yet: the page's report lands", NarrationLead.caughtUp(reported: 0.5, narrated: nil))
    check("a page at the narrated spot has caught up", NarrationLead.caughtUp(reported: 0.5, narrated: 0.5))
    check("a page past it too", NarrationLead.caughtUp(reported: 0.6, narrated: 0.5))
    check("a page still behind does not pull the saved place back", !NarrationLead.caughtUp(reported: 0.49, narrated: 0.5))
    check("a report with no progression proves nothing", !NarrationLead.caughtUp(reported: nil, narrated: 0.5))
    check("a NaN report proves nothing either", !NarrationLead.caughtUp(reported: .nan, narrated: 0.5))
    check("a narrated spot that can't be measured holds no lead", NarrationLead.caughtUp(reported: 0.4, narrated: .infinity))
    check("the very last sentence of a book", NarrationLead.caughtUp(reported: 1.0, narrated: 1.0))
}
