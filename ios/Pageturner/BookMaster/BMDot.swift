import SwiftUI

/// A notification dot: round and in the accent for the suite, blue and square for Quest Log (see `BMDotTone`).
struct BMDot: View {
    let tone: BMDotTone
    var size: CGFloat = 9
    /// A ring in the colour of what it sits on, so a dot over an icon stays clear of it.
    var ring: Color?

    var body: some View {
        shape
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shape: some View {
        switch tone {
        case .regular:
            Circle().fill(Color.ptAccent)
                .overlay { if let ring { Circle().stroke(ring, lineWidth: 1.5) } }
        case .questLog:
            let corner = size * 0.28
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.blue)
                .overlay {
                    if let ring { RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(ring, lineWidth: 1.5) }
                }
        }
    }
}
