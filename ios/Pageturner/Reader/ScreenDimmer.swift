import UIKit

/// Turns the screen down while a book is read aloud with the hands off, and gives the light back (`NarrationDim` holds
/// how far and when). The brightness the app sets outlives it on the home screen, so it is always given back before the
/// app leaves the front (`ReaderView`, at `.inactive` and on leaving the reader).
@MainActor
enum ScreenDimmer {
    /// The brightness before it was turned down, and the level it was turned down to; nil when it is not.
    private static var held: (saved: Double, applied: Double)?

    static var isDimmed: Bool { held != nil }

    static func dim() {
        guard held == nil else { return }
        let screen = UIScreen.main
        let now = Double(screen.brightness)
        guard NarrationDim.worthDimming(now) else { return }
        let target = NarrationDim.dimmed(from: now)
        held = (now, target)
        screen.brightness = CGFloat(target)
    }

    static func restore() {
        guard let held else { return }
        self.held = nil
        let screen = UIScreen.main
        if let back = NarrationDim.restored(saved: held.saved, applied: held.applied, now: Double(screen.brightness)) {
            screen.brightness = CGFloat(back)
        }
    }
}
