import SwiftUI

/// The shared thread on one book, and a way to offer it to the other reader.
struct BookNotesView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var thread: BMThread?
    @State private var error: String?
    @State private var info: String?
    @State private var loading = true
    @State private var draft = ""
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            List {
                Section("Comments") {
                    if let thread {
                        if thread.comments.isEmpty {
                            Text("Nothing said yet").foregroundStyle(.secondary)
                        }
                        ForEach(thread.comments) { comment in
                            commentRow(comment, mine: comment.userId == thread.you)
                        }
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                Section("Add a comment") {
                    TextField("Say something about this book", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                    Button("Post") { Task { await post() } }
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Suggest it") {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                    Button("Suggest to the other reader") { Task { await suggest() } }
                        .disabled(sending)
                }
                if let info { Section { Text(info).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .ptSoftScrollEdges()
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func commentRow(_ comment: BMComment, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mine ? "You" : comment.displayName).font(.subheadline.weight(.semibold))
                if let at = comment.atPercent {
                    Text("at \(Int(at.rounded()))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let content = comment.content {
                Text(content)
            } else {
                // left further on than you have read — sealed, not hidden
                Label("Sealed until you get further in", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            thread = try await BookMaster.shared.fetchComments(ref: book.bookMasterRef)
            error = nil
        } catch {
            if thread == nil { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func post() async {
        sending = true
        defer { sending = false }
        do {
            try await BookMaster.shared.postComment(
                ref: book.bookMasterRef,
                content: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggest() async {
        sending = true
        defer { sending = false }
        do {
            let to = try await BookMaster.shared.suggest(ref: book.bookMasterRef, note: note)
            info = "Suggested to \(to ?? "the other reader")"
            note = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
            info = nil
        }
    }
}
