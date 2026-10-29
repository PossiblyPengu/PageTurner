/// How far the voice is ahead of the page in a book being read aloud.
///
/// While a narrated place is held, the saved position belongs to the voice — the page only
/// follows it. A place the navigator reports *behind* the narrated one (a page still catching
/// up, or a webview reloaded to where it was when the phone locked) must not pull the saved
/// place back; one at or past it has caught up and may take it.
enum NarrationLead {
    /// Whether a reported page progression may replace the narrated one: nothing narrated
    /// yet (or a narrated spot that can't be measured — a non-finite progression holds no
    /// lead), or the report is at or past where the voice is. A nil or non-finite *reported*
    /// progression proves nothing — the narrated place keeps the lead.
    static func caughtUp(reported: Double?, narrated: Double?) -> Bool {
        guard let narrated, narrated.isFinite else { return true }
        guard let reported, reported.isFinite else { return false }
        return reported >= narrated
    }
}
