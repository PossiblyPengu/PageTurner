import SwiftUI

/// Where a book should open when it is next opened, if something asked for a particular place — a highlight
/// picked from the hub. Read once, by the reader as it opens.
@MainActor
enum OpenAt {
    private static var pending: [UUID: String] = [:]
    static func request(_ locatorJSON: String, for book: UUID) { pending[book] = locatorJSON }
    static func take(for book: UUID) -> String? { pending.removeValue(forKey: book) }
}

/// Every highlight in every book, searchable by colour and text — and a random one to come back to.
struct HighlightsHubView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var color: HighlightColor?
    @State private var revisitID: UUID?

    struct Item: Identifiable {
        let book: Book
        let highlight: Highlight
        var id: UUID { highlight.id }
    }

    private var all: [Item] {
        library.books.flatMap { book in book.highlights.map { Item(book: book, highlight: $0) } }
            .sorted { $0.highlight.createdAt > $1.highlight.createdAt }
    }

    private var shown: [Item] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { item in
            if let color, HighlightColor(saved: item.highlight.color) != color { return false }
            return tokens.allSatisfy { token in
                item.highlight.text.localizedStandardContains(token)
                    || (item.highlight.note ?? "").localizedStandardContains(token)
                    || item.book.title.localizedStandardContains(token)
            }
        }
    }

    private var revisit: Item? {
        let items = all
        return items.first { $0.id == revisitID } ?? items.first
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, color == nil, library.books.contains(where: { !$0.words.isEmpty }) {
                    Section {
                        NavigationLink {
                            SavedWordsView()
                        } label: {
                            Label("Saved Words", systemImage: "character.book.closed")
                        }
                    }
                }
                if query.isEmpty, color == nil, let item = revisit {
                    Section {
                        row(item, large: true)
                        Button {
                            revisitID = all.randomElement()?.id
                        } label: {
                            Label("Another", systemImage: "shuffle")
                        }
                    } header: {
                        Text("Revisit")
                    }
                }
                Section(shown.count == 1 ? "1 highlight" : "\(shown.count) highlights") {
                    ForEach(shown) { row($0, large: false) }
                }
            }
            .overlay {
                if all.isEmpty {
                    ContentUnavailableView(
                        "No Highlights Yet", systemImage: "highlighter",
                        description: Text("Select text in a book and choose Highlight."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .ptSoftScrollEdges()
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query, prompt: "Text, notes and books")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Colour", selection: $color) {
                            Text("All colours").tag(HighlightColor?.none)
                            ForEach(HighlightColor.allCases) { c in
                                Label(c.label, systemImage: "circle.fill").tint(c.color).tag(HighlightColor?.some(c))
                            }
                        }
                    } label: {
                        Image(systemName: color == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter by colour")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { revisitID = all.randomElement()?.id }
        }
    }

    private func row(_ item: Item, large: Bool) -> some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.highlight.text.isEmpty ? "Highlight" : item.highlight.text)
                    .font(large ? .body : .callout)
                    .lineLimit(large ? 8 : 4)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(HighlightColor(saved: item.highlight.color).color).frame(width: 4)
                    }
                if let note = item.highlight.note, !note.isEmpty {
                    Text(note).font(.footnote.italic()).foregroundStyle(.secondary).lineLimit(3)
                }
                Text([item.book.title, item.highlight.chapter].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the book at this highlight")
    }

    private func open(_ item: Item) {
        OpenAt.request(item.highlight.locatorJSON, for: item.book.id)
        dismiss()
        // a book already open is closed first, so the reader that opens reads the request
        if router.reading?.id == item.book.id { router.reading = nil }
        DispatchQueue.main.async { router.open(item.book, library: library) }
    }
}
