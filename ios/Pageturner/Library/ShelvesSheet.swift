import SwiftUI

/// What the shelves sheet is acting on: one book (from its detail or menu) or
/// the books ticked in select mode.
struct ShelfTarget: Identifiable {
    let id = UUID()
    let bookIDs: [UUID]
}

/// Put books on shelves, take them off, make new ones, rename or delete them.
struct ShelvesSheet: View {
    let target: ShelfTarget
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?

    private var title: String {
        target.bookIDs.count == 1 ? "Shelves" : "Shelves for \(target.bookIDs.count) Books"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if library.shelves.isEmpty {
                        Text("A shelf is a name you give a group of books — “Holiday reads”, “Next up”.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.shelves, id: \.self) { name in
                        Button { toggle(name) } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: icon(for: library.state(of: name, among: target.bookIDs)))
                                    .foregroundStyle(Color.ptAccent)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = name } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = name
                                renaming = name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .accessibilityValue(accessibilityState(library.state(of: name, among: target.bookIDs)))
                    }
                } footer: {
                    if !library.shelves.isEmpty { Text("Swipe a shelf to rename or delete it. Deleting a shelf keeps its books.") }
                }
                Section {
                    Button { showNew = true } label: { Label("New Shelf…", systemImage: "plus") }
                }
            }
            .ptSoftScrollEdges()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New Shelf", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    if let name = library.addShelf(newName) {
                        library.setShelf(name, on: target.bookIDs, member: true)
                    }
                    newName = ""
                }
                .disabled(nameProblem(newName, renaming: nil) != nil)
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text(nameProblem(newName, renaming: nil) ?? "The selected books go onto it.")
            }
            .confirmationDialog(
                "Delete shelf “\(deleting ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Shelf", role: .destructive) {
                    if let name = deleting { library.deleteShelf(name) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its books stay in your library.")
            }
            .alert("Rename Shelf", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let old = renaming { library.renameShelf(old, to: renameText) }
                    renaming = nil
                }
                .disabled(nameProblem(renameText, renaming: renaming) != nil)
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                if let problem = nameProblem(renameText, renaming: renaming) { Text(problem) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Why a shelf name can't be used, nil when it can. A new shelf may reuse an
    /// existing name (the books go onto that shelf); a rename may not.
    private func nameProblem(_ raw: String, renaming old: String?) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name." }
        if name.count > 40 { return "Names can be up to 40 characters." }
        if let old {
            if name.hasPrefix("~") { return "A name can’t start with “~”." }
            if library.shelves.contains(where: { $0 != old && $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return "Name already used."
            }
        }
        return nil
    }

    /// All on it → take them off; otherwise (none or some) → put them all on.
    private func toggle(_ name: String) {
        let on = library.state(of: name, among: target.bookIDs) == .all
        library.setShelf(name, on: target.bookIDs, member: !on)
    }

    private func icon(for state: LibraryStore.ShelfState) -> String {
        switch state {
        case .none: return "circle"
        case .some: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }

    private func accessibilityState(_ state: LibraryStore.ShelfState) -> String {
        switch state {
        case .none: return "not on this shelf"
        case .some: return "some of the books"
        case .all: return "on this shelf"
        }
    }
}
