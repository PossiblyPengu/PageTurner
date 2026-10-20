import CoreImage
import SwiftUI
import UIKit

/// One context for every cover: creating a CIContext is the expensive part.
private let coverTintContext = CIContext(options: [.workingColorSpace: NSNull()])

extension UIImage {
    /// The average colour of the image, for tinting a backdrop to match a cover.
    /// Nil when it can't be worked out; callers fall back to the accent.
    var averageColor: UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let extent = input.extent
        guard !extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        coverTintContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)
        return UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// The cover's colour fading into the sheet, so the page belongs to the book.
struct CoverTintBackdrop: View {
    let tint: Color

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.35), Color(.systemGroupedBackground)],
            startPoint: .top, endPoint: .center
        )
        .ignoresSafeArea()
    }
}
