import SwiftUI

/// "The Story So Far" (More menu): the story in a paragraph, and chapter by chapter, from what has been read —
/// made on the phone by Apple's model (`StoryTeller`), and never from anything past the reader's place.
struct StorySoFarSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var teller: StoryTeller
    private let load: () async -> [StoryChapter]
    @State private var chapters: [StoryChapter] = []

    init(bookID: UUID, title: String, load: @escaping () async -> [StoryChapter]) {
        _teller = StateObject(wrappedValue: StoryTeller(bookID: bookID, bookTitle: title))
        self.load = load
    }

    var body: some View {
        NavigationStack {
            List {
                if let story = teller.story {
                    Section("In Short") {
                        Text(story).textSelection(.enabled)
                    }
                }
                progress
                if !teller.recaps.isEmpty {
                    Section("Chapter by Chapter") {
                        ForEach(teller.recaps) { recap in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recap.partial ? "\(recap.chapter) (so far)" : recap.chapter)
                                    .font(.subheadline.weight(.semibold))
                                Text(recap.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(recap.declined ? .secondary : .primary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if teller.skipped > 0, !teller.isWorking {
                    Section {
                        Button("Recap From the Beginning") { teller.tell(chapters, fromStart: true) }
                    } footer: {
                        Text(teller.skipped == 1
                             ? "One earlier chapter isn’t recapped yet. Recaps are kept, so this is quicker next time."
                             : "\(teller.skipped) earlier chapters aren’t recapped yet. That takes a while the first time; recaps are kept, so it is quicker after.")
                    }
                }
                Section {
                } footer: {
                    Text("Made on this iPhone by Apple Intelligence from what you’ve read so far, and nothing after it. It can get things wrong.")
                }
            }
            .navigationTitle("The Story So Far")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                chapters = await load()
                teller.tell(chapters, fromStart: false)
            }
            .onDisappear { teller.cancel() }
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch teller.phase {
        case .idle:
            Section { ProgressView("Gathering what you’ve read…") }
        case let .reading(done, total):
            Section {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Reading chapter \(min(done + 1, total)) of \(total)…")
                }
            }
        case .telling:
            Section { ProgressView("Putting the story together…") }
        case let .failed(message):
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        case .done:
            EmptyView()
        }
    }
}

/// "Who's This?" (the selection menu): what the passages read so far say about a name, from Apple's model.
struct WhoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var teller = WhoTeller()
    let name: String
    let book: String
    let load: () async -> [StoryChapter]

    var body: some View {
        NavigationStack {
            List {
                switch teller.phase {
                case .looking:
                    ProgressView("Looking through what you’ve read…")
                case let .answered(answer, mentions):
                    Section {
                        Text(answer).textSelection(.enabled)
                    } footer: {
                        Text("From \(mentions == 1 ? "one passage" : "\(mentions) passages") you’ve read, by Apple Intelligence on this iPhone. Nothing past your place is used. It can get things wrong.")
                    }
                case let .failed(message):
                    Label(message, systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { teller.ask(about: name, book: book, chapters: await load()) }
            .onDisappear { teller.cancel() }
        }
        .presentationDetents([.medium, .large])
    }
}
