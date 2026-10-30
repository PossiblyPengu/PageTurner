import SwiftUI

/// The strip docked above the tab bar while a book is being read aloud and its reader is not on screen — the
/// text-to-speech twin of `MiniPlayer`, in the same place. Tapping the title opens the book at the place the voice
/// has reached; pressing and holding it offers the sleep timer and Stop (the reader's own bar has both too).
struct NarrationMiniPlayer: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var readAloud: ReadAloud
    let cover: UIImage?
    let onOpen: () -> Void

    /// The chapter being read, else the author.
    private var subtitle: String? {
        NowPlayingBar.subtitle(chapter: model.chapterTitle, author: model.book.author)
    }

    /// Below this width — the bottom accessory's inline placement, beside the tab icons — a title and three
    /// controls don't fit: the skip buttons and the subtitle step aside, play/pause stays.
    private static let compactBelow: CGFloat = 340

    /// How far through the book the voice is — the narrated spot when it is known,
    /// else the saved place.
    private var fraction: Double {
        let at = model.currentLocator?.locations.totalProgression ?? model.book.progression ?? 0
        return min(max(at, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            row(compact: proxy.size.width < Self.compactBelow)
        }
        .frame(height: 44)
        .overlay(alignment: .top) {
            // a hairline of how far through the book the voice has read
            GeometryReader { geo in
                Capsule()
                    .fill(Color.ptAccent)
                    .frame(width: geo.size.width * fraction, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Group {
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Image(systemName: "book.closed.fill")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.ptAccent.opacity(0.25))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.book.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !compact {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .imageScale(.small)
                                    .accessibilityHidden(true)
                                Text(subtitle ?? "Reading aloud")
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reading aloud: \(model.book.title)")
            .accessibilityHint("Opens the book")
            .contextMenu { menu }
            .accessibilityAction(named: "Stop reading aloud") { model.stopReadAloud() }

            if !compact {
                control("backward.fill", label: "Previous sentence") { readAloud.previous() }
            }

            control(readAloud.isPlaying ? "pause.fill" : "play.fill", label: readAloud.isPlaying ? "Pause" : "Play") {
                readAloud.playPause()
            }

            if !compact {
                control("forward.fill", label: "Next sentence") { readAloud.next() }
            }
        }
        .padding(.horizontal, 16)
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .ptSymbolSwap(on: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var menu: some View {
        if let left = readAloud.estimatedRemaining {
            Text("\(ReadingPace.label(minutesLeft: left / 60)) in the book")
        }
        Menu("Sleep timer", systemImage: "moon") {
            Button("Off") { readAloud.setSleepTimer(minutes: nil) }
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("In \(minutes) minutes") { readAloud.setSleepTimer(minutes: minutes) }
            }
            Button("At the end of the chapter") { readAloud.setSleepTimer(atChapterEnd: true) }
        }
        Button("Stop reading aloud", systemImage: "xmark", role: .destructive) { model.stopReadAloud() }
    }
}
