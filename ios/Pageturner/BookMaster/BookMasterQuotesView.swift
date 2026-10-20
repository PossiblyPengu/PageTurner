import SwiftUI

/// Every line and note kept on BookMaster, grouped under the book it came
/// from — newest first, the way the bridge hands them over.
struct BookMasterQuotesView: View {
    /// Set from a book's detail: only that row's lines.
    var pin: String? = nil

    @State private var quotes: [BMQuote]?
    @State private var error: String?
    @State private var loading = true

    /// Book-by-book, in the order the lines arrived.
    private var groups: [(title: String, rows: [BMQuote])] {
        var order: [String] = []
        var byTitle: [String: [BMQuote]] = [:]
        for quote in quotes ?? [] {
            let title = quote.title ?? "Unknown book"
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(quote)
        }
        return order.map { ($0, byTitle[$0] ?? []) }
    }

    var body: some View {
        List {
            if let quotes, quotes.isEmpty {
                ContentUnavailableView(
                    "Nothing kept yet", systemImage: "quote.bubble",
                    description: Text("Hold a line in the reader to save it here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.rows) { quote in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(quote.content)
                            HStack(spacing: 6) {
                                if quote.isNote { Text("Note") }
                                if let page = quote.pageNumber { Text("· p. \(page)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) { Task { await takeBack(quote) } }
                        }
                    }
                }
            }
            if loading, quotes == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .ptSoftScrollEdges()
        .navigationTitle(pin == nil ? "Quotes & notes" : "Kept lines")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard BookMaster.shared.isLinked else {
            quotes = []
            loading = false
            return
        }
        do {
            quotes = try await BookMaster.shared.fetchQuotes(pin: pin)
            error = nil
        } catch {
            if quotes == nil { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func takeBack(_ quote: BMQuote) async {
        do {
            try await BookMaster.shared.remove(.quote, id: quote.id)
            quotes?.removeAll { $0.id == quote.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
