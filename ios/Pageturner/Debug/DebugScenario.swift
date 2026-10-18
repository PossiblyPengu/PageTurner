#if DEBUG
import AVFoundation
import SwiftUI
import UIKit

/// Test hooks for the CI simulator run (.github/workflows/ios-sim.yml). Launch
/// arguments choose a screen and seed sample books, so every screen can be
/// photographed with nobody tapping:
///
///     -PTDebugSeed 1            fill an empty library with sample books, a listen and some history
///     -PTDebugScreen library    which screen to put up (see `run`)
///     -PTDebugReaderSheet …     with `reader`: contents | settings | search | voices | readaloud
///     -PTDebugReaderScroll 1    with `reader`: lay the book out as one scrolling page
///     -PTDebugHighlights …      with readaloud: which of sentence,line,word to light (comma separated)
///     -PTDebugVoice neural      with readaloud: speak with the downloaded Piper voice (en_US-lessac-low)
///     -PTDebugSettingsPush …    with `settings`: voices (open the voice list), or a page: bookmaster, notifications,
///                               chat, reading, readaloud, playback, appearance, library, backup, diagnostics
///     -PTDebugSpeechProbe 1     log the installed voices and how long speech takes at each rate
///     -PTDebugNeuralProbe <key> download that neural voice, speak with it, log the result (+ -PTDebugNeuralPlay 1)
///     -PTDebugVoiceSource neural  open the voice list on its Neural tab
///
/// Debug builds only — none of this is in the IPA.
@MainActor
enum DebugScenario {
    private static let defaults = UserDefaults.standard

    static var readerSheet: String? { defaults.string(forKey: "PTDebugReaderSheet") }
    static var settingsPush: String? { defaults.string(forKey: "PTDebugSettingsPush") }
    static var voiceSource: String? { defaults.string(forKey: "PTDebugVoiceSource") }

    /// The highlights and voice a `readaloud` launch asks for.
    static func configureReadAloud(_ settings: inout ReaderSettings) {
        if let spec = defaults.string(forKey: "PTDebugHighlights") {
            let chosen = Set(spec.split(separator: ",").map(String.init))
            settings.highlights = ReadAloudHighlights(
                sentence: chosen.contains("sentence"), line: chosen.contains("line"), word: chosen.contains("word"))
        }
        if defaults.string(forKey: "PTDebugVoice") == "neural" {
            settings.voiceIdentifier = "piper:en_US-lessac-low"
        }
        if defaults.bool(forKey: "PTDebugReaderScroll") {
            settings.scroll = true
        }
    }

    /// A reader linked to a made-up BookMaster: a shelf (one book of which is in the seeded library), numbers, a partner.
    private static func linkForPhotos() {
        func decode<T: Decodable>(_ json: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        let shelf: [BMShelfRow] = decode("""
        [{"userBookId":"u1","bookId":"b1","title":"Moby-Dick","author":"Herman Melville","status":"reading","percent":18},
         {"userBookId":"u2","bookId":"b2","title":"Piranesi","author":"Susanna Clarke","status":"want_to_read","upNext":1,"isbn":"9781635575637"},
         {"userBookId":"u3","bookId":"b3","title":"The Dispossessed","author":"Ursula K. Le Guin","status":"want_to_read","upNext":2},
         {"userBookId":"u4","bookId":"b4","title":"Hyperion","author":"Dan Simmons","status":"reading","percent":64,"format":"paper"},
         {"userBookId":"u5","bookId":"b5","title":"Emma","author":"Jane Austen","status":"read","rating":4},
         {"userBookId":"u6","bookId":"b6","title":"Walden","author":"Henry David Thoreau","status":"abandoned"}]
        """) ?? []
        let together: BMTogether? = decode("""
        {"partner":{"name":"Sam","online":true,"reading":{"title":"Dune","author":"Frank Herbert","percent":41}},
         "nudges":[{"id":"n1","note":"You would love this one","fromName":"Sam","title":"Piranesi","author":"Susanna Clarke"}],
         "sent":[{"id":"s1","status":"pending","note":"Your turn","title":"Emma","toName":"Sam"}],
         "notices":[{"id":"bookmaster:chat:3","app":"bookmaster","text":"Sam: how is it?","path":"/chat"},
                    {"id":"quest-log:1","app":"quest-log","text":"Something new for you","path":"/quest-log"},
                    {"id":"kindred:ask:a1","app":"kindred","text":"Sam asked you a question","path":"/ask"}]}
        """)
        let overview: BMOverview? = decode("""
        {"stats":{"currentStreak":12,"longestStreak":31,"booksFinished":18,"minutesRead":5230,"quotesSaved":44},
         "goals":[{"id":"g1","type":"yearly_books","target":24,"current":18,"progress":0.75},
                  {"id":"g2","type":"monthly_books","target":2,"current":1,"progress":0.5}],
         "recentAchievements":[{"id":"a1","name":"Week-long streak","icon":"🔥"},{"id":"a2","name":"Ten books","icon":"📚"}]}
        """)
        let bm = BookMaster.shared
        bm.debugLink(shelf: shelf, together: together, overview: overview)
        bm.debugStats = decode("""
        {"xp":4120,"level":7,"xpForNext":5200,"xpProgress":0.62,"currentStreak":12,"longestStreak":31,
         "booksFinished":18,"totalPages":6140,"minutesRead":5230,"quotesSaved":44,"authorsRead":11,"genresRead":6,
         "recentActivity":[{"session_date":"2024-05-01","pages":88,"sessions":2},
                           {"session_date":"2024-05-03","pages":41,"sessions":1}],
         "currentlyReading":[{"id":"u1","current_page":150,"status":"reading","format":"ebook",
                              "title":"Moby-Dick","author":"Herman Melville","total_pages":600}]}
        """)
        bm.debugPartnerShelf = decode("""
        {"partner":{"id":"u2","name":"Sam","level":6,"xp":3600},"year":2024,"booksThisYear":9,"pagesThisYear":3020,
         "stats":{"currentStreak":5,"minutesRead":2810},
         "books":[{"id":"p1","book_id":"b9","status":"read","current_page":400,"format":"ebook","rating":5,
                   "title":"Dune","author":"Frank Herbert","total_pages":400,"percent":100},
                  {"id":"p2","book_id":"b2","status":"reading","current_page":120,"format":"ebook","rating":null,
                   "title":"Piranesi","author":"Susanna Clarke","total_pages":250,"percent":48}]}
        """)
        let quotesReply: BMQuotesReply? = decode("""
        {"quotes":[{"id":"q1","userBookId":"u1","content":"It is a way I have of driving off the spleen.",
                    "type":"quote","pageNumber":41,"created_at":"2024-04-02","title":"Moby-Dick","author":"Herman Melville"},
                   {"id":"q2","userBookId":"u5","content":"Half agony, half hope.","type":"note","pageNumber":null,
                    "created_at":"2024-03-18","title":"Emma","author":"Jane Austen"}]}
        """)
        bm.debugQuotes = quotesReply?.quotes
        let achievementsReply: BMAchievementsReply? = decode("""
        {"achievements":[{"id":"a1","name":"Week-long streak","description":"Read seven days in a row","icon":"🔥",
                          "category":"streak","xp_reward":20,"earned":true,"earned_at":"2024-04-01","progress":1},
                         {"id":"a2","name":"Twenty books","description":"Finish twenty books","icon":"📚",
                          "category":"books","xp_reward":50,"earned":false,"progress":0.9}]}
        """)
        bm.debugAchievements = achievementsReply?.achievements
        bm.debugWrapped = decode("""
        {"year":2024,"booksRead":18,"pagesRead":6140,"sessionsCount":96,"topGenre":"Sci-Fi","bestDay":"Sunday",
         "longestBook":{"title":"Moby-Dick","author":"Herman Melville","total_pages":600},
         "fastestBook":{"title":"Emma","author":"Jane Austen","days":3},
         "longestSession":{"title":"Dune","duration_minutes":140},
         "firstBook":{"title":"Emma","start_date":"2024-01-03"},
         "lastBook":{"title":"Piranesi","finish_date":"2024-11-30"},
         "monthlyActivity":[{"month":"01","sessions":9,"pages":420},{"month":"02","sessions":7,"pages":310}]}
        """)
        bm.debugRecommendations = decode("""
        {"authors":["Frank Herbert","Ursula K. Le Guin"],"subjects":["Sci-Fi","Classic"],
         "partner":{"name":"Sam"},
         "partnerPicks":[{"open_library_id":"OL1","title":"The Left Hand of Darkness","author":"Ursula K. Le Guin",
                          "rating":5,"genres":["Sci-Fi"],"published_year":1969,"total_pages":304}]}
        """)
        bm.debugSeries = decode("""
        [{"id":"s1","name":"Dune Chronicles","author":"Frank Herbert","total_books":6,
          "total_in_series":6,"books_read":1,"books_owned":2},
         {"id":"s2","name":"Realm of the Elderlings","author":"Robin Hobb","total_books":16,
          "total_in_series":9,"books_read":0,"books_owned":3}]
        """)
        bm.debugSeriesDetail = decode("""
        {"series":{"id":"s1","name":"Dune Chronicles","author":"Frank Herbert","total_books":6},
         "books":[{"id":"b9","title":"Dune","author":"Frank Herbert","position":1,"published_year":1965,
                   "status":"read","user_book_id":"u9","rating":5},
                  {"id":"b10","title":"Dune Messiah","author":"Frank Herbert","position":2,"published_year":1969,
                   "status":"want_to_read","user_book_id":"u10"},
                  {"id":"b11","title":"Children of Dune","author":"Frank Herbert","position":3,
                   "published_year":1976}]}
        """)
        bm.debugDetail = decode("""
        {"catalogue":{"id":"b1","title":"Moby-Dick","author":"Herman Melville","total_pages":600,
                      "published_year":1851,"description":"The whale, again.","genres":"[\\"Classic\\"]"},
         "book":{"userBookId":"u1","bookId":"b1","title":"Moby-Dick","author":"Herman Melville",
                 "status":"reading","percent":25,"rating":null,"currentPage":150,"totalPages":600},
         "theirs":{"name":"Sam","status":"read","rating":5,"percent":100,"finish_date":"2024-03-01"},
         "sessions":[{"id":"s1","pages_start":100,"pages_end":150,"duration_minutes":80,"session_date":"2024-05-01"}],
         "quotes":[{"id":"q1","content":"It is a way I have of driving off the spleen.","type":"quote","page_number":41}],
         "comments":[{"id":"c1","content":"Wait until the end.","user_id":"u2","display_name":"Sam",
                      "at_percent":90,"ahead":true,"created_at":"2024-04-01"}],
         "you":"u1","at_percent":25}
        """)
    }

    static func run(library: LibraryStore, router: AppRouter, selectTab: @escaping (AppTab) -> Void) async {
        if defaults.bool(forKey: "PTDebugSpeechProbe") { Task { await SpeechProbe.run() } }
        if let voice = defaults.string(forKey: "PTDebugNeuralProbe") {
            let play = defaults.bool(forKey: "PTDebugNeuralPlay")
            Task { await NeuralProbe.run(key: voice, play: play) }
        }
        if defaults.bool(forKey: "PTDebugLinked") { linkForPhotos() }
        let seeding = defaults.bool(forKey: "PTDebugSeed")
        let screen = defaults.string(forKey: "PTDebugScreen")
        guard seeding || screen != nil else { return }
        if seeding, library.books.isEmpty { await seed(library) }
        guard let screen else { return }

        try? await Task.sleep(nanoseconds: 800_000_000)
        // Moby-Dick is the one with progress, shelves, highlights and a bookmark
        let text = library.books.first { $0.title == "Moby-Dick" } ?? library.books.first { !$0.isAudio }
        let audio = library.books.first { $0.isAudio }
        switch screen {
        case "library", "search": selectTab(.library)
        case "reading": selectTab(.reading)
        case "stats", "bmprogress", "bmwrapped": selectTab(.stats)
        case "together", "bmtogether": selectTab(.together)
        // the Books tab hosts the shelf and pushes the rest itself
        case "shelf", "bmbook", "bmquotes", "bmdiscover", "bmsearch", "bmseries":
            selectTab(.books)
        case "settings": router.showSettings = true
        case "detail": router.detail = text
        case "edit": router.editing = text
        case "shelves": if let text { router.openShelves([text.id]) }
        case "reader": router.reading = text; selectTab(.reading)
        case "pdf": router.reading = library.books.first { $0.ext == "pdf" }; selectTab(.reading)
        case "cbz": router.reading = library.books.first { $0.ext == "cbz" }; selectTab(.reading)
        case "player": if let audio { PlaybackCoordinator.shared.start(audio, library: library); selectTab(.reading) }
        case "link": router.showLink = true
        case "resume":
            // BookMaster has Alice at 62% and this phone has never opened her: opening asks
            if let alice = library.books.first(where: { $0.title.hasPrefix("Alice") }) {
                library.updateBookMaster(alice.id) { $0.bmRemotePercent = 62; $0.bmStatus = "reading" }
                router.open(library.books.first { $0.id == alice.id } ?? alice, library: library)
            }
        default: break
        }
    }

    // MARK: Sample data

    private struct Sample {
        var title: String
        var author: String
        var paragraphs: [String]
    }

    private static let samples = [
        Sample(title: "Moby-Dick", author: "Herman Melville", paragraphs: [
            "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. It is a way I have of driving off the spleen and regulating the circulation.",
            "Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly November in my soul; whenever I find myself involuntarily pausing before coffin warehouses, and bringing up the rear of every funeral I meet—then, I account it high time to get to sea as soon as I can. This is my substitute for pistol and ball.",
            "There is nothing surprising in this. If they but knew it, almost all men in their degree, some time or other, cherish very nearly the same feelings towards the ocean with me.",
        ]),
        Sample(title: "Pride and Prejudice", author: "Jane Austen", paragraphs: [
            "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
            "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.",
            "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?” Mr. Bennet replied that he had not.",
        ]),
        Sample(title: "Alice’s Adventures in Wonderland", author: "Lewis Carroll", paragraphs: [
            "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”",
            "So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.",
        ]),
    ]

    private static func markdown(_ sample: Sample) -> String {
        var out = "# \(sample.title)\n\n*\(sample.author)*\n\n"
        for chapter in 1...8 {
            out += "## Chapter \(chapter)\n\n"
            for i in 0..<6 {
                out += sample.paragraphs[(chapter + i) % sample.paragraphs.count] + "\n\n"
            }
        }
        return out
    }

    /// A WAV of silence — enough for the player to have something to open.
    private static func silence(seconds: Int, to url: URL) {
        let rate = 8_000
        let bytes = seconds * rate * 2
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(bytes))
        data.append(Data(count: bytes))
        try? data.write(to: url)
    }

    private static func writePDF(to url: URL) {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "The Quick Brown Fox",
            kCGPDFContextAuthor as String: "A. Typist",
        ]
        let data = UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("Page \(page)" as NSString).draw(
                    at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
                ("The quick brown fox jumps over the lazy dog. Pageturner reads PDFs too, and finds words like fox on page \(page)." as NSString)
                    .draw(in: CGRect(x: 72, y: 130, width: 468, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        try? data.write(to: url)
    }

    private static func writeCBZ(to url: URL) {
        var zip = ZipWriter()
        let colours: [UIColor] = [.systemTeal, .systemOrange, .systemPurple]
        for (i, colour) in colours.enumerated() {
            let png = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).pngData { context in
                colour.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
                ("\(i + 1)" as NSString).draw(
                    at: CGPoint(x: 320, y: 450),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 300), .foregroundColor: UIColor.white])
            }
            zip.add(String(format: "page-%02d.png", i + 1), png)
        }
        try? zip.finish().write(to: url)
    }

    private static func seed(_ library: LibraryStore) async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-seed-\(UUID().uuidString)", isDirectory: true)
        let audioDir = dir.appendingPathComponent("The Silent Audiobook", isDirectory: true)
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var urls: [URL] = []
        for sample in samples {
            let url = dir.appendingPathComponent("\(sample.title).md")
            try? markdown(sample).write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        for chapter in 1...3 {
            let url = audioDir.appendingPathComponent("Chapter \(chapter).wav")
            silence(seconds: 40, to: url)
            urls.append(url)
        }
        // a PDF with real text (to search) and a CBZ comic of three coloured pages
        let pdf = dir.appendingPathComponent("The Quick Brown Fox.pdf")
        writePDF(to: pdf)
        let cbz = dir.appendingPathComponent("Three Panels.cbz")
        writeCBZ(to: cbz)
        urls += [pdf, cbz]
        await library.importFiles(urls)

        // some state to look at: one book part-read, one nearly done, shelves, history
        let books = library.books
        if let first = books.first(where: { $0.title == "Moby-Dick" }) {
            var b = first
            b.progression = 0.42
            b.lastOpenedAt = Date()
            b.author = "Herman Melville"
            // highlights and a bookmark for the Contents sheet to list (their locators are
            // empty on purpose — they can be shown and edited, just not jumped to)
            let day = Date().addingTimeInterval(-86_400)
            b.highlights = [
                Highlight(locatorJSON: "{}", text: "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse…",
                          createdAt: day, chapter: "Chapter 1", progression: 0.02),
                Highlight(locatorJSON: "{}", text: "It is a way I have of driving off the spleen and regulating the circulation.",
                          createdAt: day.addingTimeInterval(60), color: "blue", note: "Love this line.", chapter: "Chapter 1", progression: 0.03),
                Highlight(locatorJSON: "{}", text: "This is my substitute for pistol and ball.",
                          createdAt: day.addingTimeInterval(120), color: "pink", chapter: "Chapter 2", progression: 0.2),
            ]
            b.bookmarks = [Bookmark(title: "Chapter 3", locatorJSON: "{}", progression: 0.25, createdAt: day)]
            library.update(b)
        }
        if let second = books.first(where: { $0.title == "Pride and Prejudice" }) {
            var b = second
            b.progression = 0.93
            b.lastOpenedAt = Date().addingTimeInterval(-86_400)
            library.update(b)
        }
        if let shelf = library.addShelf("Favourites") {
            library.setShelf(shelf, on: books.prefix(2).map(\.id), member: true)
        }
        _ = library.addShelf("To read")

        let log = ReadingLog.shared
        if log.sessions.isEmpty, let book = books.first {
            for (daysAgo, minutes) in [(0, 34.0), (1, 52.0), (2, 18.0), (3, 41.0), (5, 25.0), (6, 63.0), (8, 12.0), (9, 47.0)] {
                log.record(
                    book: book, minutes: minutes, from: 0.1, to: 0.2,
                    audio: daysAgo % 3 == 0, at: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
            }
        }
    }
}
#endif
