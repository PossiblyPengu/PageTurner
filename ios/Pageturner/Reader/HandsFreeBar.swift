import SwiftUI

/// The hands-free turner's controls, above the reader's footer while it runs: slower, the pace with the time gone on
/// this page, quicker, and stop.
struct HandsFreeBar: View {
    let state: ReaderModel.HandsFree
    let onSlower: () -> Void
    let onQuicker: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            barButton("tortoise", label: "Slower", action: onSlower)
            VStack(spacing: 4) {
                Text(state.held ? "Waiting" : HandsFreePace.label(state.secondsPerPage))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let turnsAt = state.turnsAt, turnsAt > Date() {
                    ProgressView(
                        timerInterval: turnsAt.addingTimeInterval(-state.secondsPerPage) ... turnsAt,
                        countsDown: false
                    ) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(.ptAccent)
                    .frame(maxWidth: 140)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.held ? "Turning pages, waiting" : "Turning pages, \(HandsFreePace.label(state.secondsPerPage))")
            barButton("hare", label: "Quicker", action: onQuicker)
            barButton("xmark", label: "Stop turning pages", action: onStop)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .ptGlassCapsule()
        .padding(.horizontal, 12)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
