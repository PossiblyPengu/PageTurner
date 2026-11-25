import SwiftUI

/// "More…" on a selection: the less used things to do with it, one tap each. The selection menu keeps iOS's own
/// (Copy, Look Up, Translate, Share) and Highlight, so it no longer pages.
struct SelectionChoicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let picked: ReaderModel.PickedText
    let canQuote: Bool
    let onChoose: (ReaderModel.SelectionChoice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("“\(picked.text)”")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Section {
                    if picked.isWord {
                        row("Save Word", "character.book.closed", .saveWord)
                    }
                    row("Read Aloud from Here", "speaker.wave.2", .readAloud)
                    if picked.isWord {
                        row("Pronounce…", "character.bubble", .pronounce)
                        if StoryAI.isAvailable {
                            row("Who’s This?", "person.text.rectangle", .who)
                        }
                    }
                    if canQuote {
                        row("Quote to BookMaster", "quote.bubble", .quote)
                    }
                }
            }
            .navigationTitle("Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: String, _ symbol: String, _ choice: ReaderModel.SelectionChoice) -> some View {
        Button {
            onChoose(choice)
        } label: {
            Label(title, systemImage: symbol)
        }
        .tint(Color.primary)
    }
}
