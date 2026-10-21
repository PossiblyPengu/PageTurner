import SwiftUI
import UIKit

/// "Pick for me" as a case opening: the to-read pile streams past a needle,
/// fast then slower with a tick each jacket, and stops on tonight's read —
/// the CS:GO unwrap, with your shelf as the cases. The spin is driven, not
/// scroll-animated, so the tick under the needle is exact. VoiceOver skips
/// the spectacle and gets the answer; Reduce Motion takes the short spin.
struct BMPickReel: View {
    /// The to-read pile, in whatever order the caller keeps it.
    let books: [BMShelfRow]
    /// Told which row won when the reader opens it — the sheet dismisses itself.
    let onPick: (BMShelfRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var resultFocused: Bool

    @State private var reel: [BMShelfRow] = []
    @State private var winner: BMShelfRow?
    @State private var landIndex = 0
    /// How far the strip has been dragged left — the driven value.
    @State private var offset: CGFloat = 0
    /// Which cell sits under the needle right now — the tick's trigger.
    @State private var centerIndex = 0
    @State private var landed = false
    @State private var width: CGFloat = 320
    /// Bumped to respin: `.task(id:)` builds a fresh reel and runs it.
    @State private var spin = 0

    private let cellWidth: CGFloat = 96
    private let gap: CGFloat = 10
    private var stride: CGFloat { cellWidth + gap }

    /// Long enough for the drama — expo-ish ease gives it the long slow tail.
    private var duration: Double {
        if UIAccessibility.isVoiceOverRunning { return 0 }
        return reduceMotion ? 0.9 : 4.8
    }

    /// The offset that puts `landIndex` dead under the needle.
    private var endOffset: CGFloat {
        CGFloat(landIndex) * stride + cellWidth / 2 - width / 2
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                headline
                reelBand
                result
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.selection, trigger: centerIndex)
            .sensoryFeedback(.success, trigger: landed)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task(id: spin) {
            // the pile emptied from under the sheet (a refresh): nothing to spin
            guard !books.isEmpty else { dismiss(); return }
            build()
            await run()
        }
    }

    private var headline: some View {
        Text(landed ? "Tonight’s read" : "The pile decides…")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .id(landed)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.25), value: landed)
    }

    /// The strip itself: covers clipped by edge fades, the needle over them.
    private var reelBand: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: gap) {
                ForEach(Array(reel.enumerated()), id: \.offset) { i, row in
                    cell(row, at: i)
                }
            }
            .offset(x: -offset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 152)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing))
        .overlay(needle)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityHidden(true)
    }

    /// One jacket in the stream; the winner gets its moment when it lands.
    private func cell(_ row: BMShelfRow, at index: Int) -> some View {
        BMCover(row: row)
            .frame(width: cellWidth)
            .scaleEffect(landed && index == landIndex ? 1.1 : 1)
            .opacity(landed && index != landIndex ? 0.45 : 1)
            .overlay {
                if landed, index == landIndex {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.ptAccent, lineWidth: 3)
                        .padding(-3)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: landed)
    }

    /// The marker everything rushes past — a glass accent pin.
    private var needle: some View {
        Capsule()
            .fill(Color.ptAccent)
            .frame(width: 5, height: 160)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }

    private var result: some View {
        VStack(spacing: 3) {
            Text(winner?.title ?? " ").font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text(winner?.author ?? " ").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(height: 46)
        .opacity(landed ? 1 : 0)
        // opacity-0 does not hide it from VoiceOver — keep the answer unspoiled
        .accessibilityHidden(!landed)
        .accessibilityFocused($resultFocused)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { again() } label: { Label("Again", systemImage: "dice") }
                .ptButtonStyle()
            Button { open() } label: { Label("Open it", systemImage: "book") }
                .ptButtonStyle(prominent: true)
        }
        .tint(.ptAccent)
        .opacity(landed ? 1 : 0)
        .allowsHitTesting(landed)
    }

    // MARK: The spin

    /// A fresh reel and a winner: enough jackets that the stop feels earned,
    /// the winner planted at the landing index, never next to its own twin.
    private func build() {
        let total = max(42, books.count * 7)
        landIndex = total - 9 - Int.random(in: 0 ..< 5)
        let win = books.randomElement()!
        var seq: [BMShelfRow] = (0 ..< total).map { _ in books.randomElement()! }
        seq[landIndex] = win
        if books.count > 1 {
            for i in 1 ..< total where i != landIndex {
                var tries = 0
                while (seq[i].userBookId == seq[i - 1].userBookId
                       || (i == landIndex - 1 && seq[i].userBookId == win.userBookId)) && tries < 40 {
                    seq[i] = books.randomElement()!
                    tries += 1
                }
            }
        }
        winner = win
        reel = seq
    }

    /// Drive the offset at display pace: the exact tick comes free because the
    /// cell under the needle is arithmetic, not a guess. Cancelled by the task.
    private func run() async {
        try? await Task.sleep(for: .milliseconds(500))   // a beat to read the room
        let span = duration
        guard !Task.isCancelled else { return }
        if span <= 0 { land(); return }
        let start = Date()
        while !Task.isCancelled {
            let p = min(1, Date().timeIntervalSince(start) / span)
            offset = endOffset * ease(p)
            tick()
            if p >= 1 { land(); return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Deep ease-out — the strip throws hard, then creeps to its stop.
    private func ease(_ p: Double) -> CGFloat {
        CGFloat(1 - pow(1 - p, 4.5))
    }

    private func tick() {
        let i = min(max(0, Int(((offset + width / 2 - cellWidth / 2) / stride).rounded())), reel.count - 1)
        if i != centerIndex { centerIndex = i }
    }

    private func land() {
        offset = endOffset
        centerIndex = landIndex
        landed = true
        resultFocused = true
    }

    private func again() {
        landed = false
        centerIndex = 0
        // the rewind rides the new spin's anticipation beat
        withAnimation(.easeIn(duration: 0.3)) { offset = 0 }
        spin += 1
    }

    private func open() {
        guard let winner else { return }
        onPick(winner)
        dismiss()
    }
}
