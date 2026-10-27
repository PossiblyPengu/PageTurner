import Foundation
import Observation
import UIKit
import UserNotifications

/// Bringing the files of a Drive book down, when the reader asks for that book — never all of a Drive at once.
///
/// The transfer is a *background* `URLSession`: iOS runs it, so it goes on with the app closed or the phone locked,
/// waits out a lost connection instead of failing, and is picked up again when the app next starts. A book's parts
/// (an audiobook is a dozen files) are separate tasks that iOS runs a few at a time. Each finished part is moved into
/// the Books folder at once — inside the delegate call, the only time the file is there — and checked against the size
/// Drive gave; when the last one is in, the book is read for its title, author and cover (`LibraryStore`) and is
/// available. A part that fails is asked for again a few times (with a fresh sign-in token when Drive said 401, with
/// what had already come when iOS kept it), and only then does the book report why.
@MainActor
@Observable
final class DriveDownloads {
    static let shared = DriveDownloads()

    /// How one book's download stands.
    struct State: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var partsDone = 0
        var parts = 0
        /// Why it stopped, when it has.
        var failure: String?

        var fraction: Double? { DriveBooks.fraction(received: received, total: total) }
    }

    /// A book in the library, as its cover shows it.
    enum Badge: Equatable {
        case available
        case downloading(Double?)
        case failed
    }

    private(set) var states: [UUID: State] = [:]

    @ObservationIgnored private let delegate = DriveDownloadDelegate()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private weak var library: LibraryStore?
    /// Bytes of the parts that have come, and of those on their way, per book and part.
    @ObservationIgnored private var done: [UUID: [Int: Int64]] = [:]
    @ObservationIgnored private var flying: [UUID: [Int: Int64]] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    /// Books whose download was called off: late reports from the tasks that were cancelled are ignored.
    @ObservationIgnored private var cancelled: Set<UUID> = []
    /// What arrived before the library was there to answer to it (a background launch).
    @ObservationIgnored private var waiting: [() -> Void] = []
    @ObservationIgnored private var backgroundDone: (() -> Void)?
    /// Books whose download was asked for on their own page: they open when they arrive (`openKey`).
    @ObservationIgnored private var opening: Set<UUID> = []

    static let cellularKey = "drive-cellular"
    /// Whether a book downloaded from its own page opens when the last part is in (on unless turned off).
    static let openKey = "drive-open-when-downloaded"
    static let identifier = "io.github.possiblypengu.pageturner.drive-downloads"
    private static let maxAttempts = 3

    private init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Open the session at launch, so what iOS finished while the app was not running is delivered.
    func reconnect() { _ = session }

    /// iOS woke the app to deliver a background session's events: say so when they have all been handled.
    func holdBackgroundCompletion(_ handler: @escaping () -> Void) { backgroundDone = handler }

    func backgroundEventsDone() {
        backgroundDone?()
        backgroundDone = nil
    }

    /// The library, once it exists: what had arrived meanwhile is dealt with, and books whose files came down while
    /// the app was closed are finished (read for their details).
    func attach(_ library: LibraryStore) {
        guard self.library == nil else { return }
        self.library = library
        let queued = waiting
        waiting = []
        for work in queued { work() }
        Task {
            for task in await session.allTasks {
                guard let ticket = DriveDownloadDelegate.Ticket(task.taskDescription) else { continue }
                ensureState(ticket.book)
                flying[ticket.book, default: [:]][ticket.index] = task.countOfBytesReceived
                refresh(ticket.book)
            }
            for book in library.books {
                guard let source = book.drive, !source.finished, states[book.id] == nil,
                      library.fileURLs(for: book).allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
                else { continue }
                await library.driveDownloadFinished(book.id)
            }
        }
    }

    /// Run `work` now, or once the library is there.
    private func whenReady(_ work: @escaping () -> Void) {
        if library != nil { work() } else { waiting.append(work) }
    }

    #if DEBUG
    /// The simulator run's photograph of a book part way down: no task is behind it.
    func debugProgress(_ id: UUID, received: Int64, total: Int64, partsDone: Int, parts: Int) {
        states[id] = State(received: received, total: total, partsDone: partsDone, parts: parts)
    }
    #endif

    // MARK: Asking

    /// What the cover of a book shows about it: waiting to be downloaded, on its way, or stuck.
    func badge(for id: UUID, inCloud: Bool) -> Badge? {
        if let state = states[id] { return state.failure == nil ? .downloading(state.fraction) : .failed }
        return inCloud ? .available : nil
    }

    func isRunning(_ id: UUID) -> Bool { states[id].map { $0.failure == nil } ?? false }

    // MARK: Starting and stopping

    /// Bring down every part of `book` that is not on the device yet. `open`: the reader asked for this one book,
    /// and it opens when it is in (an ebook, with the app in front and no other book in the reader).
    func start(_ book: Book, library: LibraryStore, open: Bool = false) {
        attach(library)
        guard let source = book.drive else { return }
        if open, !book.isAudio { opening.insert(book.id) }
        if isRunning(book.id) { return }
        cancelled.remove(book.id)
        let names = library.fileURLs(for: book).map(\.lastPathComponent)
        let need = DriveBooks.pending(source, names: names, size: { library.localSize(of: $0) })
        guard !need.isEmpty else {
            states[book.id] = nil
            Task { await library.driveDownloadFinished(book.id) }
            return
        }
        guard GoogleAuth.shared.signedIn else {
            states[book.id] = State(failure: DriveError.notSignedIn.message)
            return
        }
        for key in attempts.keys where key.hasPrefix(book.id.uuidString) { attempts[key] = nil }
        var came: [Int: Int64] = [:]
        for index in source.parts.indices where !need.contains(index) {
            came[index] = source.parts[index].size ?? library.localSize(of: names[index]) ?? 0
        }
        done[book.id] = came
        flying[book.id] = [:]
        states[book.id] = State(
            received: came.values.reduce(0, +), total: source.bytes, partsDone: came.count, parts: source.parts.count)
        Log.event("drive", "download started: \(book.title) — \(need.count) of \(source.parts.count) parts")
        let tickets = need.map { index in
            DriveDownloadDelegate.Ticket(
                book: book.id, index: index, name: names[index], size: source.parts[index].size ?? 0,
                file: source.parts[index].id)
        }
        Task {
            let running = Set(await session.allTasks.compactMap(\.taskDescription))
            for ticket in tickets where !running.contains(ticket.description) { await enqueue(ticket) }
        }
    }

    /// Stop bringing a book down. What has come stays (and is not asked for again).
    func cancel(_ id: UUID) {
        cancelled.insert(id)
        opening.remove(id)
        states[id] = nil
        done[id] = nil
        flying[id] = nil
        let prefix = id.uuidString
        Task {
            for task in await session.allTasks where task.taskDescription?.hasPrefix(prefix) == true { task.cancel() }
        }
    }

    /// Ask Drive for one part: a task in the background session, with a fresh token (or, after a failure that kept
    /// part of the file, from where it stopped).
    private func enqueue(_ ticket: DriveDownloadDelegate.Ticket, resume: Data? = nil) async {
        // a book that has failed or been cancelled asks for nothing more (a retry that was waiting comes too late)
        guard let state = states[ticket.book], state.failure == nil else { return }
        do {
            let task: URLSessionDownloadTask
            if let resume {
                task = session.downloadTask(withResumeData: resume)
            } else {
                guard let url = GoogleDrive.downloadURL(id: ticket.file) else { throw DriveError(message: "That Drive address can’t be used.") }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(try await GoogleAuth.shared.accessToken())", forHTTPHeaderField: "Authorization")
                request.allowsCellularAccess = UserDefaults.standard.object(forKey: Self.cellularKey) as? Bool ?? true
                task = session.downloadTask(with: request)
            }
            task.taskDescription = ticket.description
            task.resume()
        } catch {
            fail(ticket.book, (error as? DriveError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: What the session reports

    func progress(_ ticket: DriveDownloadDelegate.Ticket, received: Int64) {
        whenReady { [self] in
            guard !cancelled.contains(ticket.book) else { return }
            ensureState(ticket.book)
            flying[ticket.book, default: [:]][ticket.index] = received
            refresh(ticket.book)
        }
    }

    /// A part is in the Books folder.
    func finished(_ ticket: DriveDownloadDelegate.Ticket, bytes: Int64) {
        whenReady { [self] in
            guard !cancelled.contains(ticket.book) else { return }
            ensureState(ticket.book)
            flying[ticket.book]?[ticket.index] = nil
            done[ticket.book, default: [:]][ticket.index] = bytes
            attempts[ticket.description] = nil
            refresh(ticket.book)
            guard let state = states[ticket.book], state.partsDone >= state.parts else { return }
            Task { await complete(ticket.book) }
        }
    }

    /// A part did not come: asked for again a few times, then the book says why.
    func failed(
        _ ticket: DriveDownloadDelegate.Ticket, status: Int, body: Data?, message: String? = nil, resume: Data? = nil
    ) {
        whenReady { [self] in
            guard !cancelled.contains(ticket.book) else { return }
            flying[ticket.book]?[ticket.index] = nil
            ensureState(ticket.book)
            guard states[ticket.book] != nil else { return }
            let tried = attempts[ticket.description] ?? 0
            // 0 is a connection that did not hold; Drive's own "busy" and "token expired" answers are worth another go
            let again = status == 0 || status == 401 || GoogleDrive.shouldRetry(status: status)
            if again, tried < Self.maxAttempts {
                attempts[ticket.description] = tried + 1
                if status == 401 { GoogleAuth.shared.discardAccessToken() }
                let keep = status == 401 ? nil : resume
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(GoogleDrive.retryDelay(attempt: tried + 1) * 1_000_000_000))
                    await enqueue(ticket, resume: keep)
                }
                return
            }
            let why = message ?? GoogleDrive.explain(status: status, body: body)
            Log.error("drive", "download failed: \(ticket.name) — \(why)")
            fail(ticket.book, why)
        }
    }

    private func fail(_ id: UUID, _ message: String) {
        var state = states[id] ?? State()
        state.failure = message
        states[id] = state
        // the rest of this book's parts would only use the data: they wait for "Try again"
        let prefix = id.uuidString
        Task {
            for task in await session.allTasks where task.taskDescription?.hasPrefix(prefix) == true { task.cancel() }
        }
    }

    private func complete(_ id: UUID) async {
        guard let library else { return }
        let title = library.books.first { $0.id == id }?.title
        await library.driveDownloadFinished(id)
        states[id] = nil
        done[id] = nil
        flying[id] = nil
        Log.event("drive", "download finished: \(title ?? id.uuidString)")
        let wanted = opening.remove(id) != nil && (UserDefaults.standard.object(forKey: Self.openKey) as? Bool ?? true)
        if wanted, UIApplication.shared.applicationState == .active {
            IntentRouter.shared.request = .openDownloaded(id)
        }
        if UIApplication.shared.applicationState != .active, let title {
            let content = UNMutableNotificationContent()
            content.title = "Downloaded"
            content.body = title
            content.sound = .default
            let request = UNNotificationRequest(identifier: "drive-\(id.uuidString)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: Bookkeeping

    /// A state for a book the session is working on, made from the library when this run of the app has none (the app
    /// was started by iOS to deliver a download, or restarted with one running).
    private func ensureState(_ id: UUID) {
        guard states[id] == nil, let library, let book = library.books.first(where: { $0.id == id }),
              let source = book.drive
        else { return }
        let names = library.fileURLs(for: book).map(\.lastPathComponent)
        let need = Set(DriveBooks.pending(source, names: names, size: { library.localSize(of: $0) }))
        var came: [Int: Int64] = [:]
        for index in source.parts.indices where !need.contains(index) {
            came[index] = source.parts[index].size ?? library.localSize(of: names[index]) ?? 0
        }
        done[id] = came
        states[id] = State(received: came.values.reduce(0, +), total: source.bytes, partsDone: came.count, parts: source.parts.count)
    }

    /// The totals of a book's state from what has come and what is on its way.
    private func refresh(_ id: UUID) {
        guard var state = states[id] else { return }
        let came = done[id] ?? [:]
        state.partsDone = came.count
        state.received = came.values.reduce(0, +) + (flying[id]?.values.reduce(0, +) ?? 0)
        if state != states[id] { states[id] = state }
    }
}

/// The session's side: callbacks arrive on a queue of the session's own, and everything is handed to the main actor —
/// except moving a finished file into place, which has to happen before the callback returns.
final class DriveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Which part of which book a task is bringing, written into the task's description so it outlives the app.
    struct Ticket: Sendable, CustomStringConvertible {
        var book: UUID
        var index: Int
        /// The file's name in the Books folder.
        var name: String
        /// Bytes Drive says it has, 0 when it did not say.
        var size: Int64
        var file: String

        init(book: UUID, index: Int, name: String, size: Int64, file: String) {
            self.book = book
            self.index = index
            self.name = name
            self.size = size
            self.file = file
        }

        init?(_ text: String?) {
            guard let parts = text?.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false), parts.count == 5,
                  let book = UUID(uuidString: String(parts[0])), let index = Int(parts[1]), let size = Int64(parts[3])
            else { return nil }
            self.init(book: book, index: index, name: String(parts[2]), size: size, file: String(parts[4]))
        }

        var description: String { "\(book.uuidString)|\(index)|\(name)|\(size)|\(file)" }
    }

    private let lock = NSLock()
    private var lastReport: [Int: Date] = [:]

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let ticket = Ticket(downloadTask.taskDescription) else { return }
        // a few times a second is plenty for a progress ring
        let now = Date()
        lock.lock()
        let due = lastReport[downloadTask.taskIdentifier].map { now.timeIntervalSince($0) >= 0.4 } ?? true
        if due { lastReport[downloadTask.taskIdentifier] = now }
        lock.unlock()
        guard due else { return }
        Task { @MainActor in DriveDownloads.shared.progress(ticket, received: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let ticket = Ticket(downloadTask.taskDescription) else { return }
        let fm = FileManager.default
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            // what came is Drive's error message, not the file
            let body = try? Data(contentsOf: location)
            try? fm.removeItem(at: location)
            Task { @MainActor in DriveDownloads.shared.failed(ticket, status: status, body: body) }
            return
        }
        // a virus-scan or quota page answers 200 with HTML: saving it makes the book "Cannot Open"
        if (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true {
            let body = try? Data(contentsOf: location)
            try? fm.removeItem(at: location)
            Task { @MainActor in
                DriveDownloads.shared.failed(ticket, status: status, body: body, message: "Drive answered with a page, not the file — the file may need the owner to allow downloads.")
            }
            return
        }
        let got = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        if ticket.size > 0, let got, got != ticket.size {
            try? fm.removeItem(at: location)
            Task { @MainActor in
                DriveDownloads.shared.failed(ticket, status: 0, body: nil, message: "\(ticket.name) did not come down whole.")
            }
            return
        }
        let destination = LibraryStore.booksFolder.appendingPathComponent(ticket.name)
        do {
            try fm.createDirectory(at: LibraryStore.booksFolder, withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            let why = error.localizedDescription
            Task { @MainActor in
                DriveDownloads.shared.failed(ticket, status: 0, body: nil, message: "Couldn’t save the download: \(why)")
            }
            return
        }
        let bytes = got ?? ticket.size
        Task { @MainActor in DriveDownloads.shared.finished(ticket, bytes: bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        lastReport[task.taskIdentifier] = nil
        lock.unlock()
        // a finished download was handled above
        guard let error, let ticket = Ticket(task.taskDescription) else { return }
        let failure = error as NSError
        let resume = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // cancelled on purpose (the book was removed, or another part failed): nothing to report
        if failure.code == NSURLErrorCancelled, resume == nil { return }
        let why = error.localizedDescription
        Task { @MainActor in
            DriveDownloads.shared.failed(ticket, status: 0, body: nil, message: why, resume: resume)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DriveDownloads.shared.backgroundEventsDone() }
    }
}
