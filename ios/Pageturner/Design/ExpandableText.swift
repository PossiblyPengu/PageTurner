import SwiftUI

/// A blurb clamped to a few lines with a More/Less toggle — short enough text
/// gets no button. Used by the book pages' descriptions.
struct ExpandableText: View {
    let text: String
    var lineLimit: Int = 5
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.subheadline)
                .lineLimit(expanded ? nil : lineLimit)
            if text.count > 240 {
                Button(expanded ? "Less" : "More") {
                    withAnimation { expanded.toggle() }
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }
}
