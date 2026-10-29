import SwiftUI

/// The Reading tab: the book you are in, one tap from where you stopped — and the others you have begun.
/// (The library is the shelf; this is the way back in.)
struct ReadingNowView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(AppRouter.self) private var router
    @ObservedObject private var log = ReadingLog.shared
    /// "Open Library" on the empty state.
    var onBrowse: () -> Void

    private var current: Book? { library.continueBook }

    /// The other books that have been started and not finished, the most recently opened first.
    private var alsoReading: [Book] {
        library.books
            .filter { $0.id != current?.id && ($0.progression ?? 0) > 0.001 && ($0.progression ?? 0) < 0.995 }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(9).map { $0 }
    }

    /// An audiobook on the go that isn't already the continue book — so a
    /// paused listen isn't lost among the also-reading covers.
    private var listening: Book? {
        library.books
            .filter { $0.isAudio && $0.id != current?.id
                && ($0.progression ?? 0) > 0.001 && ($0.progression ?? 0) < 0.995 }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .first
    }

    /// The next volume of a series whose latest book was finished, if it has not been started.
    private var nextVolume: Book? {
        library.books
            .filter { ($0.progression ?? 0) >= 0.995 && $0.series != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .lazy
            .compactMap { library.nextInSeries(after: $0) }
            .first { ($0.progression ?? 0) < 0.001 && $0.id != current?.id }
    }

    /// "~2 h 10 min left" at this reader's pace, for a book of text.
    private func timeLeft(_ book: Book) -> String? {
        guard !book.isAudio, let pace = ReadingPace.minutesPerBook(log.sessions, bookID: book.id),
              let left = ReadingPace.minutesLeft(progress: book.progression ?? 0, minutesPerBook: pace)
        else { return nil }
        return ReadingPace.label(minutesLeft: left)
    }

    /// "Done around Mar 2 at this pace", from the last three weeks of sittings with this book.
    private func finishForecast(_ book: Book) -> String? {
        guard let forecast = ReadingTrends.forecast(log.sessions, bookID: book.id, progress: book.progression ?? 0) else { return nil }
        return ReadingTrends.label(forecast)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if AppPrefs.statsTracking { ReadingGoalCard() }
                    if let book = current {
                        ContinueCard(book: book, cover: library.coverThumbnail(for: book, maxPixels: 640)) {
                            router.open(book, library: library)
                        }
                        if let left = timeLeft(book) {
                            Label(left, systemImage: "clock")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        if let finish = finishForecast(book) {
                            Label(finish, systemImage: "calendar")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Nothing in progress", systemImage: "book")
                        } description: {
                            Text("Open a book from your library and it waits for you here.")
                        } actions: {
                            Button("Open Library", action: onBrowse)
                            Button { router.showImporter = true } label: {
                                Label("Add Books", systemImage: "plus")
                            }
                        }
                        .padding(.top, 60)
                    }
                    if let audio = listening {
                        ListeningRow(book: audio, cover: library.coverThumbnail(for: audio, maxPixels: 200)) {
                            router.open(audio, library: library)
                        }
                    }
                    if let next = nextVolume {
                        NextInSeriesRow(book: next, cover: library.coverThumbnail(for: next, maxPixels: 200)) {
                            router.open(next, library: library)
                        }
                    }
                    PartnerStrip()
                    if !alsoReading.isEmpty {
                        Text("Also reading").font(.title3.weight(.semibold))
                        BookGrid(books: alsoReading)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
                .ptReadableWidth()
            }
            .ptSoftScrollEdges()
            .navigationTitle("Reading")
            .toolbar { SettingsToolbarItem(router: router) }
        }
    }
}

/// "Continue reading" — the cover, how far along you are, and one button.
struct ContinueCard: View {
    let book: Book
    let cover: UIImage?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // beside the cover normally; under it when the text is large enough to need the width
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            BookCoverView(book: book, cover: cover, showsBadges: false, corner: 8)
                .frame(width: typeSize.isAccessibilitySize ? 110 : 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.isAudio ? "Keep listening" : "Continue reading")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ptAccent)
                    .textCase(.uppercase)
                Text(book.title)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                ProgressView(value: min(max(book.progression ?? 0, 0), 1))
                    .tint(.ptAccent)
                    .ptAnimation(.smooth(duration: 0.6), value: book.progression)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((min(max(book.progression ?? 0, 0), 1) * 100).rounded())) percent")
                    .padding(.top, 2)
                Button(action: action) {
                    Label(book.isAudio ? "Play" : "Read", systemImage: book.isAudio ? "play.fill" : "book.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .ptButtonStyle(prominent: true)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.ptAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
    }
}