import Foundation

/// How far "Dim the screen while it reads" turns the screen down, and when it gives the light back. Pure, so it is
/// checked on Linux; `ScreenDimmer` is what moves the screen's brightness.
///
/// The setting used to set `UIScreen.wantsSoftwareDimming`, which only lets the screen go below its lowest step when
/// the brightness is already there — so nothing was dimmed, and a book read aloud with "Keep screen awake" on held the
/// screen at full brightness for as long as the voice went on: the largest single drain of a long listen.
enum NarrationDim {
    /// Hands off this long (the controls hidden, no sheet up) before the screen is turned down. The controls hide a
    /// few seconds after a touch: dimming then would darken a page someone is still reading along with.
    static let delay: TimeInterval = 15

    /// The brightness to turn down to: about a third of where it is, never brighter than it was, and never so low
    /// that the page cannot be made out at a glance.
    static func dimmed(from brightness: Double) -> Double {
        guard brightness.isFinite else { return brightness }
        let now = min(max(brightness, 0), 1)
        return min(now, max(0.05, now * 0.35))
    }

    /// Whether turning down to `dimmed(from:)` is worth doing at all: a screen already at its lowest is left alone.
    static func worthDimming(_ brightness: Double) -> Bool {
        guard brightness.isFinite else { return false }
        return dimmed(from: brightness) < min(max(brightness, 0), 1) - 0.02
    }

    /// The brightness to give back when the hands come back: what it was, unless the screen is no longer at the level
    /// it was turned down to — someone (or auto-brightness) has moved it since, and theirs stands.
    static func restored(saved: Double, applied: Double, now: Double) -> Double? {
        guard saved.isFinite, applied.isFinite, now.isFinite else { return nil }
        return abs(now - applied) < 0.02 ? min(max(saved, 0), 1) : nil
    }
}
