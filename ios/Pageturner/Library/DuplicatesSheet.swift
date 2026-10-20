import SwiftUI

/// Copies of one book, with a button to fold them into the one worth keeping.
struct DuplicatesSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [[Book]] = []
    @State private var confirming: [Book]?

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Duplicates", systemImage: "checkmark.circle",
                        description: Text("Every book in the library is a different one."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(groups, id: \.first?.id) { group in
                        Section {
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, book in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(book.title).font(.body.weight(index == 0 ? .semibold : .regular)).lineLimit(2)
                                        Text(detail(book, keep: index == 0))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if index == 0 {
                                        Text("Keep").font(.caption.weight(.semibold)).foregroundStyle(Color.ptAccent)
                                    }
                                }
                            }
                            Button("Merge into one") { confirming = group }
                        } footer: {
                            Text("Highlights, bookmarks and shelves are kept; the extra files are deleted.")
                        }
                    }
                }
            }
            .ptSoftScrollEdges()
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { groups = library.duplicateGroups() }
            .confirmationDialog(
                "Merge these copies?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible, presenting: confirming
            ) { group in
                Button("Merge, keep the first", role: .destructive) {
                    library.merge(keep: group[0].id, removing: group.dropFirst().map(\.id))
                    groups = library.duplicateGroups()
                }
            } message: { group in
                Text("\(group.count - 1) extra \(group.count == 2 ? "copy is" : "copies are") removed from this device.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func detail(_ book: Book, keep: Bool) -> String {
        var parts = [book.ext.uppercased()]
        if let p = book.progression, p > 0 { parts.append("\(Int((p * 100).rounded()))%") }
        let marks = book.highlights.count + book.bookmarks.count
        if marks > 0 { parts.append("\(marks) marked") }
        parts.append("added " + book.addedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

/// The nudge to save a copy of the library somewhere else.
struct BackupReminder: View {
    let onBackUp: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(Color.ptAccent).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Back up your library").font(.subheadline.weight(.semibold))
                Text("A sideloaded app can be wiped when its signing lapses. A backup keeps your books, places and highlights.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button("Back Up", action: onBackUp).font(.subheadline.weight(.semibold))
                Button("Later", action: onLater).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.ptAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
