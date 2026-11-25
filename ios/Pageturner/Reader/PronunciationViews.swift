import SwiftUI

/// Teach the voice how to say a word: what is printed, how it sounds, and whether it is for one book or every book.
/// From the reader's selection menu ("Pronounce") and Settings → Read Aloud → Pronunciations.
struct PronunciationEditor: View {
    /// A book the entry can be kept for.
    struct BookChoice {
        let id: UUID
        let title: String
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PronunciationStore.shared
    @ObservedObject private var preview = SpeechPreview.shared

    private let original: Pronunciation
    /// The book it can be kept for — the one being read, or the entry's own; nil for an entry of every book's
    /// made in Settings.
    private let book: BookChoice?
    private let voiceID: String?
    private let rate: Double

    @State private var written: String
    @State private var said: String
    @State private var onlyThisBook: Bool

    init(entry: Pronunciation, book: BookChoice?, voiceID: String?, rate: Double) {
        original = entry
        self.book = book
        self.voiceID = voiceID
        self.rate = rate
        _written = State(initialValue: entry.written)
        _said = State(initialValue: entry.said)
        _onlyThisBook = State(initialValue: entry.bookID != nil)
    }

    private var exists: Bool { store.entries.contains { $0.id == original.id } }
    private var saidText: String { said.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { Pronunciations.cleaned(written) != nil && !saidText.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Word", text: $written)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Say it like", text: $said, prompt: Text("her-MY-oh-nee"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        preview.say(saidText, voiceID: voiceID, rate: rate)
                    } label: {
                        Label(preview.playing == nil ? "Hear It" : "Stop",
                              systemImage: preview.playing == nil ? "play.fill" : "stop.fill")
                    }
                    .disabled(saidText.isEmpty)
                } footer: {
                    Text("Spell it the way it sounds. Hyphens split it into parts and capitals can stress one — try a few spellings and listen. It is used by every voice, from the next sentence.")
                }
                if let book {
                    Section {
                        Toggle("Only in \(book.title)", isOn: $onlyThisBook)
                    } footer: {
                        Text(onlyThisBook ? "Other books keep saying it their own way." : "Every book says it like this.")
                    }
                }
                if exists {
                    Section {
                        Button("Forget This Word", role: .destructive) {
                            store.remove(original.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(exists ? "Pronunciation" : "Teach the Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onDisappear { preview.stop() }
        }
    }

    private func save() {
        var entry = original
        entry.written = written
        entry.said = saidText
        entry.bookID = onlyThisBook ? book?.id : nil
        store.save(entry)
        dismiss()
    }
}

/// Settings → Read Aloud → Pronunciations: every word taught, every book's first, then each book's own.
struct PronunciationListView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = PronunciationStore.shared
    @State private var editing: Pronunciation?

    let voiceID: String?
    let rate: Double

    private struct BookEntries: Identifiable {
        let id: UUID
        let title: String
        let entries: [Pronunciation]
    }

    private var everyBook: [Pronunciation] { store.entries.filter { $0.bookID == nil } }

    private var books: [BookEntries] {
        let byBook = Dictionary(grouping: store.entries.filter { $0.bookID != nil }) { $0.bookID! }
        return byBook.map { id, entries in BookEntries(id: id, title: title(of: id), entries: entries) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Words Taught Yet",
                    systemImage: "character.bubble",
                    description: Text("Select a word in a book and choose Pronounce to teach the voice how to say it, or add one here."))
            }
            if !everyBook.isEmpty {
                Section("Every Book") {
                    ForEach(everyBook) { row($0) }
                        .onDelete { remove($0, from: everyBook) }
                }
            }
            ForEach(books) { group in
                Section(group.title) {
                    ForEach(group.entries) { row($0) }
                        .onDelete { remove($0, from: group.entries) }
                }
            }
        }
        .navigationTitle("Pronunciations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = Pronunciation(written: "", said: "")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Teach a Word")
            }
        }
        .sheet(item: $editing) { entry in
            PronunciationEditor(
                entry: entry,
                book: entry.bookID.map { .init(id: $0, title: title(of: $0)) },
                voiceID: voiceID, rate: rate)
        }
    }

    private func row(_ entry: Pronunciation) -> some View {
        Button {
            editing = entry
        } label: {
            LabeledContent {
                Text(entry.said)
            } label: {
                Text(entry.written).foregroundStyle(.primary)
            }
        }
    }

    private func remove(_ offsets: IndexSet, from entries: [Pronunciation]) {
        for index in offsets { store.remove(entries[index].id) }
    }

    private func title(of id: UUID) -> String {
        library.books.first { $0.id == id }?.title ?? "A removed book"
    }
}
