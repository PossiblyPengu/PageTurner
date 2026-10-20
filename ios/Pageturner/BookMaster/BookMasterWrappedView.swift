import SwiftUI

/// The year in books — the wrap BookMaster works out from the reads and the
/// sittings: the counts, the longest and the quickest, when reading happened.
struct BookMasterWrappedView: View {
    @State private var wrapped: BMWrapped?
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var error: String?
    @State private var loading = true
    @State private var sharing: SharedImage?

    var body: some View {
        List {
            Section {
                Stepper(value: $year, in: 1970...Calendar.current.component(.year, from: Date())) {
                    HStack {
                        Text("Year")
                        Spacer()
                        Text(String(year)).foregroundStyle(.secondary)
                    }
                }
            }
            if let wrapped {
                Section("\(String(wrapped.year)) in numbers") {
                    LabeledContent("Books finished", value: "\(wrapped.booksRead)")
                    LabeledContent("Pages read", value: "\(Int(wrapped.pagesRead))")
                    LabeledContent("Sessions", value: "\(wrapped.sessionsCount)")
                    if let genre = wrapped.topGenre { LabeledContent("Top genre", value: genre) }
                    if let day = wrapped.bestDay { LabeledContent("Best day", value: day) }
                }
                highlightsSection(wrapped)
                if !wrapped.monthlyActivity.isEmpty { monthsSection(wrapped.monthlyActivity) }
            } else if !loading {
                ContentUnavailableView(
                    "Nothing to wrap", systemImage: "calendar",
                    description: Text("Reads and sessions on BookMaster make the year."))
                    .listRowBackground(Color.clear)
            }
            if loading, wrapped == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .ptSoftScrollEdges()
        .navigationTitle("The year so far")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let wrapped, wrapped.booksRead > 0 || wrapped.sessionsCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let image = WrappedCard.image(wrapped) { sharing = SharedImage(image: image) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share \(String(wrapped.year)) as an image")
                }
            }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.image]) }
        .refreshable { await load() }
        // a new year cancels the request for the old one, so a late reply cannot land under the wrong label
        .task(id: year) { await load() }
    }

    /// The superlatives — longest, quickest, longest sitting, first and last.
    private func highlightsSection(_ wrapped: BMWrapped) -> some View {
        Section("Highlights") {
            if let book = wrapped.longestBook {
                LabeledContent("Longest book",
                    value: "\(book.title ?? "—")\(book.totalPages.map { " · \($0)p" } ?? "")")
            }
            if let book = wrapped.fastestBook {
                LabeledContent("Quickest",
                    value: "\(book.title ?? "—")\(book.days.map { " · \(Int($0)) days" } ?? "")")
            }
            if let sitting = wrapped.longestSession {
                LabeledContent("Longest sitting",
                    value: "\(sitting.durationMinutes ?? 0)m\(sitting.title.map { " · \($0)" } ?? "")")
            }
            if let first = wrapped.firstBook {
                LabeledContent("First book", value: first.title ?? "—")
            }
            if let last = wrapped.lastBook {
                LabeledContent("Last book", value: last.title ?? "—")
            }
        }
    }

    /// Month by month, sittings and pages.
    private func monthsSection(_ months: [BMWrappedMonth]) -> some View {
        Section("Month by month") {
            ForEach(months, id: \.month) { month in
                LabeledContent(
                    Self.monthName(month.month),
                    value: "\(month.sessions ?? 0) sittings · \(Int(month.pages ?? 0)) pages")
            }
        }
    }

    private static func monthName(_ mm: String) -> String {
        guard let n = Int(mm), (1...12).contains(n) else { return mm }
        return Calendar.current.monthSymbols[n - 1]
    }

    private func load() async {
        guard BookMaster.shared.isLinked else {
            wrapped = nil
            loading = false
            return
        }
        do {
            let fetched = try await BookMaster.shared.fetchWrapped(year: year)
            guard !Task.isCancelled else { return }
            wrapped = fetched
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            // numbers for another year must not stay up under this year's label
            if wrapped == nil || wrapped?.year != year { wrapped = nil; self.error = error.localizedDescription }
        }
        loading = false
    }
}
