import Foundation

/// Where the reader was before a jump — a link in the page, the contents, a
/// search hit, the scrubber — so a "Back" button can take them there again, the
/// way Kindle's "Return to page" does. Pure logic over progressions; the reader
/// keeps the locators (as JSON) inside the spots.
struct JumpHistory {
    /// A place in the book.
    struct Spot: Equatable {
        /// A Readium `Locator`, as JSON.
        var locatorJSON: String
        var href: String
        /// 0…1 through the whole book.
        var progression: Double
    }

    struct Entry: Equatable {
        /// Where to go back to.
        var origin: Spot
        /// 0…1 through the book where the jump actually landed — what "reading on"
        /// is measured from. Known only once the reader has reported the landing.
        var landedAt: Double?
    }

    /// A hop within one file that moves less than this (a share of the book) is
    /// not worth a way back.
    static let minimumDistance = 0.01
    /// Reading this far past where a jump landed means the reader has moved on.
    static let moveOnDistance = 0.08
    static let capacity = 20

    /// Oldest first.
    private(set) var entries: [Entry] = []

    /// The place a "Back" button would return to.
    var back: Spot? { entries.last?.origin }

    /// Remember `origin` as somewhere to come back to after a jump to `landed`.
    /// Returns whether it was kept.
    @discardableResult
    mutating func record(origin: Spot, landed: Spot) -> Bool {
        if origin.href == landed.href, abs(origin.progression - landed.progression) < Self.minimumDistance {
            return false
        }
        // jumping on from near where the last jump came from is the same way back
        if let last = entries.last,
           last.origin.href == origin.href,
           abs(last.origin.progression - origin.progression) < Self.minimumDistance
        {
            entries[entries.count - 1].landedAt = nil
            return false
        }
        entries.append(Entry(origin: origin, landedAt: nil))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return true
    }

    /// Take the way back: the place to return to, now forgotten.
    mutating func goBack() -> Spot? {
        entries.popLast()?.origin
    }

    /// The reader reported a new position. The first one after a jump is where
    /// it landed; once the reader is well past that, the way back is dropped.
    /// A non-finite report (a half-reloaded webview answers 0/0) is ignored —
    /// stored, it would compare false to everything and pin the way back forever.
    mutating func readOn(to progression: Double) {
        guard progression.isFinite, let i = entries.indices.last else { return }
        guard let landed = entries[i].landedAt else {
            entries[i].landedAt = progression
            return
        }
        if abs(progression - landed) > Self.moveOnDistance { entries.removeAll() }
    }

    mutating func clear() { entries.removeAll() }
}
