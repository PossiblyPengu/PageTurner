import Foundation

/// How long the hands-free turner leaves a page up: the share of the book one page is, measured from the pages
/// turned, times the minutes this reader takes over a whole book (`ReadingPace`). Pure, so it is checked on Linux.
enum HandsFreePace {
    static let shortest: TimeInterval = 5
    static let longest: TimeInterval = 300
    /// With nothing to go on yet: about a phone page of prose at 250 words a minute.
    static let fallback: TimeInterval = 45

    /// The steps worth keeping for `pageShare`: `step` (how far a turn moved through the book) added when it is one
    /// page forward — not a step back, nor a jump — and only the latest `keep`.
    static func noting(_ step: Double, in steps: [Double], keep: Int = 12) -> [Double] {
        guard step.isFinite, step > 0, step < 0.05 else { return steps }
        return Array((steps + [step]).suffix(keep))
    }

    /// The share of the book one page is: the middle of the steps seen, so the short last page of a chapter and the
    /// odd long one count for little. Nil with fewer than two to go on.
    static func pageShare(steps: [Double]) -> Double? {
        let usable = steps.filter { $0.isFinite && $0 > 0 && $0 < 0.05 }.sorted()
        guard usable.count >= 2 else { return nil }
        let mid = usable.count / 2
        return usable.count % 2 == 1 ? usable[mid] : (usable[mid - 1] + usable[mid]) / 2
    }

    /// Seconds a page takes at the reader's pace, in whole seconds; nil without a pace or a page to measure by.
    static func seconds(pageShare: Double?, minutesPerBook: Double?) -> TimeInterval? {
        guard let pageShare, let minutesPerBook, pageShare > 0, minutesPerBook > 0,
              pageShare.isFinite, minutesPerBook.isFinite
        else { return nil }
        return clamped((pageShare * minutesPerBook * 60).rounded())
    }

    static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return fallback }
        return min(max(seconds, shortest), longest)
    }

    /// A step quicker or slower: a tenth either way, at least a second, in whole seconds.
    static func adjusted(_ seconds: TimeInterval, quicker: Bool) -> TimeInterval {
        let change = max((seconds * 0.1).rounded(), 1)
        return clamped((quicker ? seconds - change : seconds + change).rounded())
    }

    /// "32 s a page", "1 min 10 s a page".
    static func label(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 60 else { return "\(whole) s a page" }
        let m = whole / 60, s = whole % 60
        return s == 0 ? "\(m) min a page" : "\(m) min \(s) s a page"
    }
}
