import Foundation

/// The floating chat button: when it is shown, and where it rests. Pure, so the rules can be checked
/// off-device; `BMChatButtonLayer` draws it.
enum BMChatButton {
    /// Shown for a linked reader who has not turned it off — and never while a book is being read, nor
    /// over a screen that is itself the chat or a web page (those say so with `hiders`).
    static func isShown(linked: Bool, enabled: Bool, readerOpen: Bool, hiders: Int) -> Bool {
        linked && enabled && !readerOpen && hiders == 0
    }

    /// Where it rests: against the left or right edge, and how far down the free height (0 top … 1 bottom).
    struct Spot: Equatable {
        var trailing: Bool
        var y: Double

        static let standardY = 0.72
        static let standard = Spot(trailing: true, y: standardY)

        init(trailing: Bool, y: Double) {
            self.trailing = trailing
            self.y = y.isFinite ? min(max(y, 0), 1) : Self.standardY
        }

        /// What is kept between launches: "t:720" — the side, and the height in thousandths.
        var stored: String { "\(trailing ? "t" : "l"):\(Int((y * 1000).rounded()))" }

        /// Nil for anything `stored` did not write.
        init?(stored: String) {
            let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let side = parts.first, side == "t" || side == "l",
                  let thousandths = Int(parts[1]), (0...1000).contains(thousandths)
            else { return nil }
            self.init(trailing: side == "t", y: Double(thousandths) / 1000)
        }

        /// The same height on the other edge.
        var flipped: Spot { Spot(trailing: !trailing, y: y) }

        /// The range the button's centre can take vertically: the free band (`top`…`bottom`) less half the
        /// button at each end, so it stays wholly inside.
        private static func reach(top: Double, bottom: Double, size: Double) -> (low: Double, high: Double) {
            let low = top + size / 2
            return (low, max(low, bottom - size / 2))
        }

        /// Where the button lands when let go with its centre at `x`, `y`: the nearer edge, and that height.
        static func dropped(x: Double, y: Double, width: Double, top: Double, bottom: Double, size: Double) -> Spot {
            let (low, high) = reach(top: top, bottom: bottom, size: size)
            return Spot(trailing: x > width / 2, y: high > low ? (y - low) / (high - low) : standardY)
        }

        /// Where its centre is, in a screen `width` wide whose free band runs `top`…`bottom`, `margin` from the edge.
        func center(width: Double, top: Double, bottom: Double, size: Double, margin: Double) -> (x: Double, y: Double) {
            let (low, high) = Self.reach(top: top, bottom: bottom, size: size)
            let x = trailing ? width - margin - size / 2 : margin + size / 2
            return (x, low + y * (high - low))
        }
    }
}
