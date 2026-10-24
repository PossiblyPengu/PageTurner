import SwiftUI

/// A place in the Drive: a folder, or the list of what others have shared.
struct DriveLocation: Hashable {
    var id: String
    var name: String
    /// "Shared with me" is a search, not a folder.
    var isSharedList = false

    static let myDrive = DriveLocation(id: "root", name: "My Drive")
    static let shared = DriveLocation(id: "shared-with-me", name: "Shared with me", isSharedList: true)

    var asFolder: GoogleDrive.File { GoogleDrive.File(id: id, name: name, mimeType: GoogleDrive.folderMime) }
}

/// What the browser holds across its folders: the files and folders ticked (a ticked folder means every book in it
/// and in the folders inside it), and the progress of bringing them in.
@Observable
@MainActor
final class DriveBrowserModel {
    private(set) var selected: [String: GoogleDrive.File] = [:]
    private(set) var selectedFolders: [String: DriveLocation] = [:]
    private(set) var working = false
    private(set) var progress = ""
    var error: String?

    /// Everything ticked, files and folders.
    var count: Int { selected.count + selectedFolders.count }

    /// "2 folders and 3 books" — what the import button says.
    var summary: String {
        var parts: [String] = []
        if !selectedFolders.isEmpty { parts.append("\(selectedFolders.count) folder\(selectedFolders.count == 1 ? "" : "s")") }
        if !selected.isEmpty { parts.append("\(selected.count) book\(selected.count == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    func isSelected(_ file: GoogleDrive.File) -> Bool { selected[file.resolved.id] != nil }
    func isSelected(folder: DriveLocation) -> Bool { selectedFolders[folder.id] != nil }

    func toggle(_ file: GoogleDrive.File) {
        let id = file.resolved.id
        if selected[id] != nil { selected[id] = nil } else { selected[id] = file.resolved }
    }

    func toggle(folder: DriveLocation) {
        if selectedFolders[folder.id] != nil { selectedFolders[folder.id] = nil } else { selectedFolders[folder.id] = folder }
    }

    /// Every book and folder in a listing.
    func select(_ files: [GoogleDrive.File]) {
        for file in files {
            if file.isFolder {
                let target = file.resolved
                selectedFolders[target.id] = DriveLocation(id: target.id, name: file.name)
            } else if GoogleDrive.isImportable(file) {
                selected[file.resolved.id] = file.resolved
            }
        }
    }

    func clear() {
        selected = [:]
        selectedFolders = [:]
    }

    /// Put what is ticked — the files, and every book under each ticked folder — in the library, without downloading
    /// it: each book is downloaded on its own, when it is asked for. True when everything was added.
    func addSelected(library: LibraryStore) async -> Bool {
        var items: [String: DriveTransfer.Item] = [:]
        let folders = selectedFolders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !folders.isEmpty {
            working = true
            error = nil
            for folder in folders {
                progress = "Looking through \(folder.name)…"
                do {
                    for found in try await DriveClient.shared.books(under: folder.id) {
                        let path = found.folder.isEmpty ? folder.name : folder.name + "/" + found.folder
                        items[found.file.id] = (found.file, path)
                    }
                } catch is CancellationError {
                    working = false
                    return false
                } catch {
                    working = false
                    self.error = (error as? DriveError)?.message ?? error.localizedDescription
                    return false
                }
            }
            working = false
        }
        // a book ticked on its own that a ticked folder also holds is added once, with its folder
        for file in selected.values where items[file.id] == nil { items[file.id] = (file, "") }
        guard !items.isEmpty else {
            error = "There are no books in what you ticked."
            return false
        }
        return await add(Array(items.values), library: library)
    }

    /// A folder and everything under it that is a book.
    func addFolder(_ folder: DriveLocation, library: LibraryStore) async -> Bool {
        working = true
        progress = "Looking through \(folder.name)…"
        error = nil
        do {
            let found = try await DriveClient.shared.books(under: folder.id)
            working = false
            guard !found.isEmpty else {
                error = "There are no books in “\(folder.name)”."
                return false
            }
            return await add(found.map { ($0.file, $0.folder.isEmpty ? folder.name : folder.name + "/" + $0.folder) }, library: library)
        } catch {
            working = false
            self.error = (error as? DriveError)?.message ?? error.localizedDescription
            return false
        }
    }

    /// The books go on the shelf at once. What cannot be a book before it is downloaded (a zip is unpacked, a text file
    /// made into an EPUB) is downloaded now, as before.
    private func add(_ items: [DriveTransfer.Item], library: LibraryStore) async -> Bool {
        let result = DriveBooks.plan(items.map { DriveBooks.Found($0.file, folder: $0.folder) }, known: library.driveFileIDs)
        let added = library.addFromDrive(result.books)
        if !added.isEmpty {
            // names are all there is to go on until a book is downloaded: look the books up for authors and covers
            let ids = added.map(\.id)
            Task { await MetadataLookup.enrichDriveBooks(ids, library: library) }
        }
        guard result.direct.isEmpty else {
            working = true
            error = nil
            defer { working = false }
            let (came, failures) = await DriveTransfer.bring(
                result.direct.map { ($0.file, $0.folder) }, into: library
            ) { [weak self] text in self?.progress = text }
            if failures.isEmpty { clear() } else {
                for file in came { selected[file.id] = nil }
                error = failures.joined(separator: "\n")
            }
            return failures.isEmpty
        }
        guard !added.isEmpty else {
            error = result.known > 0 ? "That is already in your library." : "There is nothing there Pageturner can add."
            return false
        }
        clear()
        return true
    }
}

/// Browsing Google Drive: My Drive and what is shared, with folders to open and book files to tick. Used to add books,
/// and — with `.chooseFolder` — to pick the folder Pageturner watches.
struct DriveBrowserView: View {
    enum Purpose { case importBooks, chooseFolder }

    let purpose: Purpose
    /// For `.chooseFolder`: what to do with the folder picked.
    var onChoose: ((GoogleDrive.File) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var model = DriveBrowserModel()
    private let auth = GoogleAuth.shared

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(purpose == .importBooks ? "Google Drive" : "Choose a Folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
        .interactiveDismissDisabled(model.working)
    }

    @ViewBuilder
    private var content: some View {
        if !auth.signedIn {
            SignInPrompt()
        } else {
            roots
        }
    }

    private var roots: some View {
        List {
            NavigationLink(value: DriveLocation.myDrive) {
                Label("My Drive", systemImage: "externaldrive")
            }
            NavigationLink(value: DriveLocation.shared) {
                Label("Shared with me", systemImage: "person.2")
            }
        }
        .ptSoftScrollEdges()
        .navigationDestination(for: DriveLocation.self) { location in
            DriveFolderView(location: location, purpose: purpose, model: model, onChoose: choose, onDone: { dismiss() })
        }
    }

    private func choose(_ folder: GoogleDrive.File) {
        onChoose?(folder)
        dismiss()
    }
}

/// Asking to sign in: the one button, and why it might not work.
private struct SignInPrompt: View {
    private let auth = GoogleAuth.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in to Google Drive")
                .font(.headline)
            Text("Pageturner reads the files you pick, and writes only its own backup folder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = auth.error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button { Task { await auth.signIn() } } label: {
                Text(auth.busy ? "Signing in…" : "Sign In with Google").frame(maxWidth: .infinity)
            }
            .ptButtonStyle(prominent: true)
            .disabled(auth.busy)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One folder's contents.
struct DriveFolderView: View {
    let location: DriveLocation
    let purpose: DriveBrowserView.Purpose
    let model: DriveBrowserModel
    let onChoose: (GoogleDrive.File) -> Void
    let onDone: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @State private var items: [GoogleDrive.File] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        list
            .navigationTitle(location.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { menu }
            .task(id: location) { await load() }
            .refreshable { await load() }
            .safeAreaInset(edge: .bottom) { actionBar }
            .alert("Google Drive", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.error ?? "")
            }
    }

    // MARK: The list

    /// Only folders when one is being chosen; folders and files otherwise.
    private var shown: [GoogleDrive.File] {
        purpose == .chooseFolder ? items.filter(\.isFolder) : items
    }

    private var list: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError).font(.footnote).foregroundStyle(.red)
                    Button("Try Again") { Task { await load() } }
                }
            }
            let known = library.driveFileIDs
            ForEach(shown) { file in
                row(file, known: known)
            }
        }
        .overlay {
            if loading, items.isEmpty { ProgressView() }
            else if !loading, shown.isEmpty, loadError == nil {
                ContentUnavailableView(
                    purpose == .chooseFolder ? "No folders here" : "Nothing here",
                    systemImage: "folder",
                    description: Text(purpose == .chooseFolder ? "Use this folder, or go back." : "No folders or files in this one."))
            }
        }
        .ptSoftScrollEdges()
    }

    @ViewBuilder
    private func row(_ file: GoogleDrive.File, known: Set<String>) -> some View {
        if file.isFolder {
            folderRow(file)
        } else if known.contains(file.resolved.id) {
            HStack {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).foregroundStyle(.secondary)
                    Text("In your library").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } else if GoogleDrive.isImportable(file) {
            Button { model.toggle(file) } label: {
                HStack {
                    Image(systemName: model.isSelected(file) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.isSelected(file) ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).foregroundStyle(.primary)
                        let size = GoogleDrive.sizeText(file.size)
                        if !size.isEmpty { Text(size).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .accessibilityAddTraits(model.isSelected(file) ? .isSelected : [])
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).foregroundStyle(.secondary)
                Text(file.isGoogleApp ? "A Google document — not a book file" : "Not a file Pageturner can add")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A folder opens when its row is tapped; the circle ticks it — all the books in it and in the folders inside it.
    @ViewBuilder
    private func folderRow(_ file: GoogleDrive.File) -> some View {
        let location = DriveLocation(id: file.resolved.id, name: file.name)
        if purpose == .importBooks {
            HStack(spacing: 10) {
                Button { model.toggle(folder: location) } label: {
                    Image(systemName: model.isSelected(folder: location) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.isSelected(folder: location) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.isSelected(folder: location) ? "Folder ticked: \(file.name)" : "Tick folder \(file.name)")
                NavigationLink(value: location) {
                    Label(file.name, systemImage: "folder")
                }
            }
        } else {
            NavigationLink(value: location) {
                Label(file.name, systemImage: "folder")
            }
        }
    }

    // MARK: The bars

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        if purpose == .importBooks, !location.isSharedList {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { model.select(items) } label: { Label("Tick Everything Here", systemImage: "checkmark.circle") }
                    Button {
                        Task { if await model.addFolder(location, library: library) { onDone() } }
                    } label: {
                        Label("Add This Folder and Its Subfolders", systemImage: "square.and.arrow.down.on.square")
                    }
                    if model.count > 0 {
                        Button(role: .destructive) { model.clear() } label: { Label("Clear Selection", systemImage: "xmark.circle") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(model.working)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if model.working {
            HStack(spacing: 10) {
                ProgressView()
                Text(model.progress).font(.footnote).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .ptGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 14)
        } else if purpose == .chooseFolder, !location.isSharedList {
            Button { onChoose(location.asFolder) } label: {
                Text("Use “\(location.name)”").frame(maxWidth: .infinity)
            }
            .ptButtonStyle(prominent: true)
            .padding(14)
        } else if purpose == .importBooks, model.count > 0 {
            Button {
                Task { if await model.addSelected(library: library) { onDone() } }
            } label: {
                Text("Add \(model.summary) to Library").frame(maxWidth: .infinity)
            }
            .ptButtonStyle(prominent: true)
            .padding(14)
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            items = location.isSharedList
                ? try await DriveClient.shared.sharedWithMe()
                : try await DriveClient.shared.children(of: location.id)
        } catch is CancellationError {
            return
        } catch {
            loadError = (error as? DriveError)?.message ?? error.localizedDescription
        }
    }
}
