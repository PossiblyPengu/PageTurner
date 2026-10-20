import SwiftUI
import UIKit

/// Every word saved from any book, newest first — tap one for its dictionary entry.
struct SavedWordsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var defining: DictionaryRequest?

    struct Entry: Identifiable {
        let book: Book
        let word: SavedWord
        var id: UUID { word.id }
    }

    struct DictionaryRequest: Identifiable {
        let term: String
        var id: String { term }
    }

    private var all: [Entry] {
        library.books.flatMap { book in book.words.map { Entry(book: book, word: $0) } }
            .sorted { $0.word.createdAt > $1.word.createdAt }
    }

    private var shown: [Entry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { entry in
            tokens.allSatisfy { token in
                entry.word.word.localizedStandardContains(token)
                    || (entry.word.context ?? "").localizedStandardContains(token)
                    || entry.book.title.localizedStandardContains(token)
            }
        }
    }

    /// One word to a line, then where it was found — for a share sheet or a notes app.
    private var export: String {
        all.map { entry in
            var line = entry.word.word
            if let context = entry.word.context { line += " — \(context)" }
            return line + " (\(entry.book.title))"
        }.joined(separator: "\n")
    }

    var body: some View {
        List {
            ForEach(shown) { entry in
                Button { defining = DictionaryRequest(term: entry.word.word) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.word.word).font(.headline)
                        if let context = entry.word.context {
                            Text(context).font(.footnote.italic()).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Text([entry.book.title, entry.word.chapter].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the dictionary entry")
                .swipeActions {
                    Button(role: .destructive) { remove(entry) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "No Saved Words", systemImage: "character.book.closed",
                    description: Text("Select a word in a book and choose Save Word."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .ptSoftScrollEdges()
        .navigationTitle("Saved Words")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, prompt: "Words and books")
        .toolbar {
            if !all.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: export) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share the list")
                }
            }
        }
        .sheet(item: $defining) { request in
            DictionarySheet(term: request.term).ignoresSafeArea()
        }
    }

    private func remove(_ entry: Entry) {
        library.mutate(entry.book.id) { $0.words.removeAll { $0.id == entry.word.id } }
    }
}

/// iOS's own dictionary, for one term. It says so itself when it has no entry.
private struct DictionarySheet: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
