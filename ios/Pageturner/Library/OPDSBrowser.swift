import Security
import SwiftUI

// Online catalogues: a Calibre content server on the home network, Project Gutenberg, any OPDS feed.
// The books come down as files and go through the same import as one picked from Files.

struct OPDSCatalog: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    var username: String?
}

/// A catalogue password, kept in the Keychain rather than with the settings.
enum OPDSKeychain {
    private static let service = "io.github.possiblypengu.pageturner.opds"

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty, let data = password.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// The catalogues the reader has added.
@MainActor
final class OPDSCatalogs: ObservableObject {
    private static let key = "opds-catalogs"
    @Published private(set) var catalogs: [OPDSCatalog] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([OPDSCatalog].self, from: data) {
            catalogs = saved
        }
    }

    func add(name: String, address: String, username: String, password: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = OPDSCatalog(
            name: cleanName.isEmpty ? (url.host ?? "Catalogue") : cleanName, url: url,
            username: user.isEmpty ? nil : user)
        OPDSKeychain.setPassword(user.isEmpty ? nil : password, for: catalog.id)
        catalogs.append(catalog)
        save()
        return true
    }

    func remove(_ catalog: OPDSCatalog) {
        OPDSKeychain.setPassword(nil, for: catalog.id)
        catalogs.removeAll { $0.id == catalog.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(catalogs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum OPDSError: LocalizedError {
    case http(Int)
    case notACatalogue

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "The server wants a username and password."
        case let .http(code): return "The server answered \(code)."
        case .notACatalogue: return "That address is not an OPDS catalogue."
        }
    }
}

/// Talks to one catalogue: signs requests, reads feeds, brings a book down as a file.
struct OPDSClient {
    let catalog: OPDSCatalog
    let password: String?

    init(catalog: OPDSCatalog) {
        self.catalog = catalog
        password = catalog.username == nil ? nil : OPDSKeychain.password(for: catalog.id)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/atom+xml, application/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let user = catalog.username, let password {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw OPDSError.http(http.statusCode) }
    }

    func feed(at url: URL) async throws -> OPDSFeed {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try check(response)
        guard let feed = OPDS.parse(data, base: response.url ?? url) else { throw OPDSError.notACatalogue }
        return feed
    }

    /// The search address for a feed that has one, fetching its OpenSearch description if it only points at it.
    func searchTemplate(for feed: OPDSFeed) async -> String? {
        if let template = feed.searchTemplate { return template }
        guard let description = feed.searchDescription,
              let (data, response) = try? await URLSession.shared.data(for: request(description)),
              (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true,
              let template = OPDS.searchTemplate(fromDescription: data)
        else { return nil }
        return URL(string: template, relativeTo: response.url ?? description)?.absoluteString.removingPercentEncoding
    }

    func search(template: String, terms: String, base: URL) async throws -> OPDSFeed {
        guard let url = OPDS.searchURL(template: template, terms: terms, base: base) else { throw OPDSError.notACatalogue }
        return try await feed(at: url)
    }

    /// Download into a temporary file named for the book, ready to hand to the importer.
    func download(_ file: OPDSDownload, title: String) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(for: request(file.url))
        try check(response)
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("opds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent((safe.isEmpty ? "Book" : String(safe.prefix(80))) + "." + file.fileExtension)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}

// MARK: - Screens

/// The catalogues, and the way to add one.
struct OPDSCatalogsView: View {
    @StateObject private var store = OPDSCatalogs()
    @State private var adding = false

    var body: some View {
        List {
            if store.catalogs.isEmpty {
                Section {
                    Text("Add a catalogue to browse and download books straight into your library. A Calibre content server on your network (its address ends in /opds) or any OPDS feed works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Your catalogues") {
                    ForEach(store.catalogs) { catalog in
                        NavigationLink {
                            OPDSFeedView(client: OPDSClient(catalog: catalog), url: catalog.url, title: catalog.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(catalog.name)
                                Text(catalog.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.remove(store.catalogs[index]) }
                    }
                }
            }
            Section("Suggestions") {
                Button {
                    _ = store.add(name: "Project Gutenberg", address: "https://m.gutenberg.org/ebooks.opds/", username: "", password: "")
                } label: {
                    Label("Project Gutenberg — 70,000 free books", systemImage: "plus.circle")
                }
                .disabled(store.catalogs.contains { $0.url.host == "m.gutenberg.org" })
            }
        }
        .navigationTitle("Online Catalogs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a catalogue")
            }
        }
        .sheet(isPresented: $adding) { AddCatalogSheet(store: store) }
    }
}

private struct AddCatalogSheet: View {
    let store: OPDSCatalogs
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Address, e.g. 192.168.1.20:8080/opds", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if invalid { Text("That doesn’t look like an address.").foregroundStyle(.red) }
                }
                Section("Sign in (if the server asks)") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            }
            .navigationTitle("Add a Catalogue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if store.add(name: name, address: address, username: username, password: password) { dismiss() } else { invalid = true }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One page of a catalogue: listings to open and books to take.
struct OPDSFeedView: View {
    let client: OPDSClient
    let url: URL
    let title: String
    @EnvironmentObject private var library: LibraryStore

    @State private var entries: [OPDSEntry] = []
    @State private var next: URL?
    @State private var searchTemplate: String?
    @State private var searchBase: URL?
    @State private var results: [OPDSEntry]?
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var busy: Set<String> = []
    @State private var added: Set<String> = []
    @State private var failed: String?

    private var shown: [OPDSEntry] { results ?? entries }

    var body: some View {
        List {
            ForEach(shown) { entry in
                if entry.downloads.isEmpty, let target = entry.navigation {
                    NavigationLink {
                        OPDSFeedView(client: client, url: target, title: entry.title)
                    } label: {
                        Label(entry.title, systemImage: "folder")
                    }
                } else if !entry.downloads.isEmpty {
                    bookRow(entry)
                }
            }
            if results == nil, let more = next {
                Button("Load more") { Task { await loadMore(more) } }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .overlay {
            if let error, entries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t open this", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if !loading, shown.isEmpty {
                ContentUnavailableView(results == nil ? "Nothing here" : "No results", systemImage: "books.vertical")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this catalogue")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty { results = nil }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert("Couldn’t get that book", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failed ?? "")
        }
    }

    private func bookRow(_ entry: OPDSEntry) -> some View {
        HStack(spacing: 12) {
            RemoteCover(url: entry.cover)
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let format = entry.downloads.first?.fileExtension {
                    Text(format.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if added.contains(entry.id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Added")
            } else if busy.contains(entry.id) {
                ProgressView()
            } else {
                Button("Get") { Task { await get(entry) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.ptAccent)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let feed = try await client.feed(at: url)
            entries = feed.entries
            next = feed.next
            searchBase = url
            searchTemplate = await client.searchTemplate(for: feed)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore(_ page: URL) async {
        loading = true
        defer { loading = false }
        if let feed = try? await client.feed(at: page) {
            entries += feed.entries.filter { new in !entries.contains { $0.id == new.id } }
            next = feed.next
        }
    }

    private func search() async {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty, let template = searchTemplate, let base = searchBase else {
            if searchTemplate == nil { failed = "This catalogue has no search." }
            return
        }
        loading = true
        defer { loading = false }
        do {
            results = try await client.search(template: template, terms: terms, base: base).entries
        } catch {
            failed = error.localizedDescription
        }
    }

    private func get(_ entry: OPDSEntry) async {
        guard let file = entry.downloads.first else { return }
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        do {
            let local = try await client.download(file, title: entry.title)
            await library.importFiles([local])
            try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
            added.insert(entry.id)
        } catch {
            failed = error.localizedDescription
        }
    }
}
