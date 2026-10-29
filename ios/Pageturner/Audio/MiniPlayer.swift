import SwiftUI

/// The strip docked above the tab bar while an audiobook is loaded.
struct MiniPlayer: View {
    @ObservedObject var player: AudioPlayer
    let onOpen: () -> Void
    // the same keys NowPlayingView and PlaybackSection bind — so a changed
    // interval retitles these icons even while playback (and its ticks) pause
    @AppStorage("audio-skip-back") private var skipBack = 15.0
    @AppStorage("audio-skip-fwd") private var skipFwd = 30.0

    /// The chapter being played, when the book has chapters; otherwise the author.
    private var subtitle: String? {
        if player.chapters.count > 1, let chapter = player.currentChapter { return chapter.title }
        return player.bookAuthor.isEmpty ? nil : player.bookAuthor
    }

    /// Below this width — the bottom accessory's inline placement, beside the tab icons — four controls and
    /// a title don't fit: the skip buttons and the subtitle step aside, play/pause stays.
    private static let compactBelow: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            row(compact: proxy.size.width < Self.compactBelow)
        }
        .frame(height: 44)
        .overlay(alignment: .top) {
            // a hairline of how far through the book — the same fraction the player scrubs
            GeometryReader { geo in
                let fraction = player.duration > 0 ? min(max(player.position / player.duration, 0), 1) : 0
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
                        if let cover = player.coverImage {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Image(systemName: "headphones")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.ptAccent.opacity(0.25))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(player.bookTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !compact, let line = subtitle {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(player.bookTitle)")
            .accessibilityHint("Opens the player")

            if !compact {
            Button { player.skip(by: -skipBack) } label: {
                Image(systemName: "gobackward.\(Int(skipBack))")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back \(Int(skipBack)) seconds")
            }

            Button { player.togglePlay() } label: {
                Group {
                    if player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .ptSymbolSwap(on: player.isPlaying)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            if !compact {
            Button { player.skip(by: skipFwd) } label: {
                Image(systemName: "goforward.\(Int(skipFwd))")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward \(Int(skipFwd)) seconds")
            }
        }
        .padding(.horizontal, 16)
    }
}
