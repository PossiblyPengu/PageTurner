import SwiftUI
import UIKit

/// Every word saved from any book, newest first, with a short definition — tap one for its dictionary entry, swipe
/// to write what it means, and Review to go through the ones due (`WordStudy`).
struct SavedWordsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var defining: DictionaryRequest?
    @State private var reviewing: [Entry]?
    @State private var noting: Entry?
    @State private var note = ""

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

    /// The words due for review now, longest waiting first.
    private var due: [Entry] {
        let entries = all
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.word.id, $0) })
        return WordStudy.due(entries.map(\.word), now: Date()).compactMap { byID[$0.id] }
    }

    /// One word to a line, then where it was found — for a share sheet or a notes app.
    private var export: String {
        all.map { entry in
            var line = entry.word.word
            if let meaning = entry.word.meaning, !meaning.isEmpty {
                line += " — \(meaning)"
            } else if let definition = entry.word.definition, !definition.isEmpty {
                line += " — \(definition)"
            }
            if let context = entry.word.context { line += " — \(context)" }
            return line + " (\(entry.book.title))"
        }.joined(separator: "\n")
    }

    var body: some View {
        List {
            ForEach(shown) { entry in
                Button { defining = DictionaryRequest(term: entry.word.word) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.word.word).font(.headline)
                            if WordStudy.isLearned(entry.word) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.ptAccent)
                                    .accessibilityLabel("Learned")
                            }
                        }
                        if let meaning = entry.word.meaning, !meaning.isEmpty {
                            Text(meaning).font(.subheadline)
                        }
                        if let definition = entry.word.definition, !definition.isEmpty {
                            Text(definition).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
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
                .swipeActions(edge: .leading) {
                    Button {
                        note = entry.word.meaning ?? ""
                        noting = entry
                    } label: {
                        Label("What It Means", systemImage: "square.and.pencil")
                    }
                    .tint(.ptAccent)
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
        .safeAreaInset(edge: .bottom) {
            if !all.isEmpty {
                Text("Definitions are from Wiktionary — only the word is sent.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
        }
        .task { await WordDefinitions.fillMissing(in: library) }
        .toolbar {
            if !due.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Review \(due.count)") { reviewing = due }
                        .accessibilityLabel("Review \(due.count) words")
                }
            }
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
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            WordReviewView(entries: reviewing ?? [])
        }
        .alert(noting.map { "What “\($0.word.word)” means" } ?? "", isPresented: Binding(
            get: { noting != nil }, set: { if !$0 { noting = nil } }
        )) {
            TextField("In your own words", text: $note)
            Button("Save") {
                if let entry = noting { setMeaning(note, for: entry) }
                noting = nil
            }
            Button("Cancel", role: .cancel) { noting = nil }
        }
    }

    private func setMeaning(_ text: String, for entry: Entry) {
        let meaning = text.trimmingCharacters(in: .whitespacesAndNewlines)
        library.mutate(entry.book.id) { book in
            guard let i = book.words.firstIndex(where: { $0.id == entry.word.id }) else { return }
            book.words[i].meaning = meaning.isEmpty ? nil : meaning
        }
    }

    private func remove(_ entry: Entry) {
        library.mutate(entry.book.id) { $0.words.removeAll { $0.id == entry.word.id } }
    }
}

/// Saved words one at a time: the word, then — when asked — its meaning and where it was found, and whether it was
/// known. A word not known comes round again before the review ends; one known stays away for its box's time.
struct WordReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [SavedWordsView.Entry]
    @State private var shown = false
    @State private var known = 0
    @State private var again = 0
    @State private var defining: SavedWordsView.DictionaryRequest?

    init(entries: [SavedWordsView.Entry]) {
        _queue = State(initialValue: entries)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let entry = queue.first {
                    card(entry)
                    if shown {
                        HStack(spacing: 12) {
                            Button { grade(entry, knew: false) } label: {
                                Label("Again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button { grade(entry, knew: true) } label: {
                                Label("Knew It", systemImage: "checkmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.ptAccent)
                        }
                        .controlSize(.large)
                    } else {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { shown = true }
                        } label: {
                            Text("Show the Meaning").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.ptAccent)
                        .controlSize(.large)
                    }
                } else {
                    ContentUnavailableView(
                        "All Done", systemImage: "checkmark.circle",
                        description: Text(again == 0 ? "\(known) known." : "\(known) known, \(again) gone over again."))
                }
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(queue.isEmpty ? "Review" : "\(queue.count) to Go")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $defining) { request in
                DictionarySheet(term: request.term).ignoresSafeArea()
            }
        }
    }

    private func card(_ entry: SavedWordsView.Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.word.word)
                .font(.largeTitle.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            if shown {
                if let meaning = entry.word.meaning, !meaning.isEmpty {
                    Text(meaning).font(.title3)
                }
                if let definition = entry.word.definition, !definition.isEmpty {
                    Text(definition).font(.body).foregroundStyle(.secondary)
                }
                if let context = entry.word.context {
                    Text(context).font(.callout.italic()).foregroundStyle(.secondary)
                }
                HStack {
                    Text(entry.book.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button("Dictionary") { defining = SavedWordsView.DictionaryRequest(term: entry.word.word) }
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func grade(_ entry: SavedWordsView.Entry, knew: Bool) {
        library.mutate(entry.book.id) { book in
            guard let i = book.words.firstIndex(where: { $0.id == entry.word.id }) else { return }
            book.words[i] = WordStudy.graded(book.words[i], knew: knew, now: Date())
        }
        withAnimation(.smooth(duration: 0.25)) {
            shown = false
            let card = queue.removeFirst()
            if knew {
                known += 1
            } else {
                again += 1
                queue.append(card)   // round again before the end
            }
        }
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
