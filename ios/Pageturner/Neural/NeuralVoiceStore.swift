import CryptoKit
import Foundation
import Observation
import UIKit

/// The installed neural voices as the speech engine needs them — readable from any thread
/// (Readium asks for a voice from a background task).
final class NeuralVoiceIndex: @unchecked Sendable {
    struct Entry {
        var voice: NeuralVoice
        var info: NeuralVoiceFormat.Installed
        var directory: URL
        /// The speaker of a multi-speaker voice the id asked for ("piper:key@3"); 0 else.
        var sid = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func replace(with new: [Entry]) {
        lock.lock()
        entries = Dictionary(new.map { ($0.voice.id, $0) }, uniquingKeysWith: { _, last in last })
        lock.unlock()
    }

    /// The entry an identifier names — "piper:key", or a speaker of it ("piper:key@3"),
    /// whose `sid` is kept inside the speakers the installed voice has.
    func entry(forID id: String) -> Entry? {
        guard let key = NeuralVoice.key(fromID: id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[NeuralVoice.idPrefix + key] else { return nil }
        entry.sid = min(max(NeuralVoice.speaker(fromID: id) ?? 0, 0), max(entry.info.speakers - 1, 0))
        return entry
    }

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }
}

/// Asks iOS for a little longer when the app is put away mid-download.
@MainActor
private final class BackgroundGrant {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "voice download") { [weak self] in
            // iOS calls this on the main thread, and wants the task ended before it returns
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The voices that can be downloaded, which are on this iPhone, and what is being fetched.
/// Voices live in Application Support (not backed up — they can always be fetched again).
@MainActor
@Observable
final class NeuralVoiceStore {
    static let shared = NeuralVoiceStore()

    enum Phase: Equatable {
        case downloading, checking, preparing
    }

    struct Transfer: Equatable {
        var phase: Phase
        /// 0…1 while downloading.
        var fraction: Double
    }

    enum Failure: Error, LocalizedError {
        case noSpace
        case badAddress
        case server(Int)
        case damaged

        var errorDescription: String? {
            switch self {
            case .noSpace: return "There isn’t enough space on this iPhone."
            case .badAddress: return "The voice’s address couldn’t be worked out."
            case let .server(code): return "The server said \(code)."
            case .damaged: return "The download was damaged — try again."
            }
        }
    }

    let catalog: NeuralCatalog
    /// Voices that are ready to speak, by key.
    private(set) var installed: [String: NeuralVoiceFormat.Installed] = [:]
    /// Voices being fetched, by key.
    private(set) var progress: [String: Transfer] = [:]
    /// Why the last attempt for a voice failed.
    private(set) var failures: [String: String] = [:]

    let index = NeuralVoiceIndex()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    private let root: URL
    private let downloader = NeuralDownloader()

    init() {
        if let url = Bundle.main.url(forResource: "NeuralVoices", withExtension: "json"),
           let data = try? Data(contentsOf: url), let decoded = try? NeuralCatalog.decode(data)
        {
            catalog = decoded
        } else {
            catalog = NeuralCatalog(repo: "https://huggingface.co/rhasspy/piper-voices", revision: "", voices: [])
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        root = support.appendingPathComponent("Pageturner/Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
        scan()
        cleanUp()
        // the background session exists from the start, so iOS can deliver what it
        // did while the app was away — and what it is still doing is picked up again
        downloader.reconnect()
        Task { await self.resumePending() }
    }

    // MARK: What there is

    func isInstalled(_ voice: NeuralVoice) -> Bool { installed[voice.key] != nil }

    func isBusy(_ voice: NeuralVoice) -> Bool { progress[voice.key] != nil }

    /// The voices on this iPhone, in the catalogue's order.
    var installedVoices: [NeuralVoice] {
        catalog.voices.filter { installed[$0.key] != nil }
    }

    /// What the installed voices take up.
    var usedBytes: Int64 {
        installedVoices.reduce(0) { $0 + $1.onnx.size }
    }

    func directory(for voice: NeuralVoice) -> URL {
        root.appendingPathComponent(voice.key, isDirectory: true)
    }

    // MARK: Getting a voice

    /// Download `voice` and make it ready. Progress is in `progress[voice.key]`; a failure in `failures`.
    func install(_ voice: NeuralVoice) {
        guard tasks[voice.key] == nil, installed[voice.key] == nil, progress[voice.key] == nil else { return }
        failures[voice.key] = nil
        progress[voice.key] = Transfer(phase: .downloading, fraction: 0)
        tasks[voice.key] = Task { [weak self] in
            // checking and unpacking after the model lands still want a little longer
            let grant = BackgroundGrant()
            defer { grant.end() }
            // whatever way the attempt ends — an early return too — the voice is not left looking busy
            defer {
                self?.progress[voice.key] = nil
                self?.tasks[voice.key] = nil
            }
            do {
                guard let self else { return }
                try await self.fetch(voice)
            } catch is CancellationError {
                // asked for
            } catch let error as URLError where error.code == .cancelled {
                // asked for
            } catch {
                self?.failures[voice.key] = error.localizedDescription
                Log.error("neural", "install \(voice.key) failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel(_ voice: NeuralVoice) {
        // a live attempt's defer clears its own progress entry; a relaunched task's does not
        tasks[voice.key]?.cancel()
        progress[voice.key] = nil
        Task { await downloader.cancelDownloads(matching: voice.key) }
    }

    /// Delete a voice from this iPhone.
    func remove(_ voice: NeuralVoice) {
        cancel(voice)
        try? FileManager.default.removeItem(at: directory(for: voice))
        installed[voice.key] = nil
        failures[voice.key] = nil
        refreshIndex()
    }

    // MARK: The download

    private func fetch(_ voice: NeuralVoice) async throws {
        guard let configURL = catalog.url(for: voice.config), let modelURL = catalog.url(for: voice.onnx) else { throw Failure.badAddress }
        try checkSpace(for: voice)

        // the small settings file first: a voice that can't be spoken is found out before 60 MB is spent
        let configData = try await fetchConfig(voice, from: configURL)
        let part = Self.partURL(for: voice.key)
        try await downloader.download(modelURL, key: voice.key, to: part)
        try await finish(voice, at: part, config: configData)
    }

    /// The small settings file, checked before the model is trusted.
    private func fetchConfig(_ voice: NeuralVoice, from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.server(code) }
        guard Self.md5(of: data) == voice.config.md5 else { throw Failure.damaged }
        _ = try NeuralVoiceFormat.parse(config: data)
        return data
    }

    /// A landed model is checked and unpacked — from `fetch` for a download that ran in front,
    /// from `downloadLanded` for one that outlived the app. `config` is the settings already in
    /// hand; nil means they are fetched again, cheap next to the model.
    private func finish(_ voice: NeuralVoice, at temporary: URL, config configData: Data? = nil) async throws {
        defer { try? FileManager.default.removeItem(at: temporary) }
        let key = voice.key
        let config: Data
        if let configData {
            config = configData
        } else {
            guard let url = catalog.url(for: voice.config) else { throw Failure.badAddress }
            config = try await fetchConfig(voice, from: url)
        }
        try Task.checkCancellation()

        progress[key] = Transfer(phase: .checking, fraction: 1)
        let expected = voice.onnx
        let intact = try await Task.detached(priority: .utility) { () throws -> Bool in
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == expected.size else { return false }
            return try Self.md5(ofFileAt: temporary) == expected.md5
        }.value
        guard intact else { throw Failure.damaged }
        try Task.checkCancellation()

        progress[key] = Transfer(phase: .preparing, fraction: 1)
        let staging = root.appendingPathComponent(key + ".installing", isDirectory: true)
        let destination = directory(for: voice)
        let languageName = voice.langName
        let info = try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: staging)
            let info = try NeuralVoiceFormat.install(
                key: key, languageName: languageName, model: temporary, config: config, into: staging)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            return info
        }.value
        installed[key] = info
        refreshIndex()
    }

    private func checkSpace(for voice: NeuralVoice) throws {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < voice.onnx.size + voice.onnx.size / 3 {
            throw Failure.noSpace
        }
    }

    // MARK: A download that outlives the app

    @ObservationIgnored private var backgroundDone: (() -> Void)?

    /// iOS woke the app to deliver a background session's events: say so when they have all been handled.
    func holdBackgroundCompletion(_ handler: @escaping () -> Void) { backgroundDone = handler }

    func backgroundEventsDone() {
        backgroundDone?()
        backgroundDone = nil
    }

    /// The session exists so iOS can deliver what happened while the app was away; a task
    /// still under way is reported as downloading again, and a model that landed is finished.
    func reconnect() {
        downloader.reconnect()
        Task { await self.resumePending() }
    }

    private func resumePending() async {
        for task in await downloader.allTasks {
            guard let tag = NeuralDownloader.Tag(task.taskDescription), installed[tag.key] == nil else { continue }
            let expected = task.countOfBytesExpectedToReceive
            progress[tag.key] = Transfer(
                phase: .downloading,
                fraction: expected > 0 ? min(1, Double(task.countOfBytesReceived) / Double(expected)) : 0)
        }
        // a .part that landed under an app that then went away is finished off now
        for voice in catalog.voices where installed[voice.key] == nil && progress[voice.key] == nil {
            let part = Self.partURL(for: voice.key)
            if FileManager.default.fileExists(atPath: part.path) {
                downloadLanded(key: voice.key, at: part, failure: nil)
            }
        }
    }

    /// The session's "how far" — for a task started before the app was relaunched too.
    func noteProgress(key: String, fraction: Double) {
        if progress[key] == nil, installed[key] == nil, catalog.voices.contains(where: { $0.key == key }) {
            progress[key] = Transfer(phase: .downloading, fraction: 0)
        }
        progress[key]?.fraction = fraction
    }

    /// A download that finished while the app was not running: iOS woke it for the session's
    /// events and there is no caller left to answer — the voice is finished off here.
    func downloadLanded(key: String, at url: URL, failure: Error?) {
        guard installed[key] == nil, tasks[key] == nil,
              let voice = catalog.voices.first(where: { $0.key == key })
        else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        progress[key] = Transfer(phase: .checking, fraction: 1)
        tasks[key] = Task { [weak self] in
            let grant = BackgroundGrant()
            defer { grant.end() }
            defer { self?.progress[key] = nil; self?.tasks[key] = nil }
            if let failure {
                try? FileManager.default.removeItem(at: url)
                self?.failures[key] = failure.localizedDescription
                Log.error("neural", "install \(key) failed: \(failure.localizedDescription)")
                return
            }
            do {
                try await self?.finish(voice, at: url)
            } catch is CancellationError {
                // asked for
            } catch let error as URLError where error.code == .cancelled {
                // asked for
            } catch {
                self?.failures[key] = error.localizedDescription
                Log.error("neural", "install \(key) failed: \(error.localizedDescription)")
            }
        }
    }

    /// A download the app was relaunched under broke on its own: show why, and stop looking busy.
    func downloadFailed(key: String, error: Error) {
        progress[key] = nil
        guard installed[key] == nil else { return }
        failures[key] = error.localizedDescription
        Log.error("neural", "install \(key) failed: \(error.localizedDescription)")
    }

    /// Where a model lands while it comes down: a name worked out from the voice, so a download
    /// that outlives its caller can be found again.
    static func partURL(for key: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(safeName(key)).part")
    }

    /// Voice keys come from the catalogue, but a file name should not trust that: anything
    /// odd becomes a dash. `nonisolated`: the background downloader names its files with it too.
    nonisolated static func safeName(_ key: String) -> String {
        key.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }

    // MARK: On disk

    private func scan() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fm = FileManager.default
        var found: [String: NeuralVoiceFormat.Installed] = [:]
        for voice in catalog.voices {
            let folder = directory(for: voice)
            guard fm.fileExists(atPath: folder.appendingPathComponent(NeuralVoiceFormat.modelFile).path),
                  fm.fileExists(atPath: folder.appendingPathComponent(NeuralVoiceFormat.tokensFileName).path),
                  let data = fm.contents(atPath: folder.appendingPathComponent(NeuralVoiceFormat.infoFile).path),
                  let info = try? decoder.decode(NeuralVoiceFormat.Installed.self, from: data)
            else { continue }
            found[voice.key] = info
        }
        installed = found
        refreshIndex()
    }

    /// What an interrupted install left behind — a staging folder is always rubbish, but a
    /// part file or kept resume data for a voice that is not in yet is picked up again
    /// (`resumePending`), not thrown away.
    private func cleanUp() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasSuffix(".installing") {
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("voice-") {
            let name = url.lastPathComponent
            let claimable = catalog.voices.contains {
                installed[$0.key] == nil
                    && (name == "voice-\(Self.safeName($0.key)).part" || name == "voice-\(Self.safeName($0.key)).resume")
            }
            if !claimable { try? fm.removeItem(at: url) }
        }
    }

    private func refreshIndex() {
        index.replace(with: installedVoices.compactMap { voice in
            installed[voice.key].map { .init(voice: voice, info: $0, directory: directory(for: voice)) }
        })
    }

    // MARK: Checksums

    nonisolated static func md5(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streamed, so a 100 MB model is never in memory.
    nonisolated static func md5(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads one file to a place of the caller's choosing.
///
/// The session is a *background* one, the same way `DriveDownloads`' is: a voice keeps
/// coming with the app put away — iOS wakes it to hand over the finished file — and a task
/// still going when the app was last open is picked up again on the next launch
/// (`NeuralVoiceStore.reconnect`). `taskDescription` carries the voice key and where the
/// file lands, so a completion that arrives under a relaunched app can still finish the
/// voice on its own.
final class NeuralDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "io.github.possiblypengu.pageturner.voices"

    private struct Job {
        var continuation: CheckedContinuation<Void, Error>
        var failure: Error?
    }

    /// `key|where the file lands` — enough to finish a download the app was relaunched under.
    struct Tag: Sendable {
        var key: String
        var destination: URL

        init(key: String, destination: URL) {
            self.key = key
            self.destination = destination
        }

        init?(_ text: String?) {
            guard let parts = text?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
            self.init(key: String(parts[0]), destination: URL(fileURLWithPath: String(parts[1])))
        }

        var description: String { "\(key)|\(destination.path)" }
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var lastReport: [Int: Date] = [:]
    /// Where an interrupted download got to, by voice key — written down too, so even a
    /// restart carries on instead of starting at 0%.
    private var resumeData: [String: Data] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// The session exists so iOS can deliver what happened while the app was away.
    func reconnect() { _ = session }

    var allTasks: [URLSessionTask] {
        get async { await session.allTasks }
    }

    /// A kept resume blob, in memory or spent from disk — either way it is taken once.
    private func savedResume(for key: String) -> Data? {
        lock.lock()
        let kept = resumeData.removeValue(forKey: key)
        lock.unlock()
        if let kept { return kept }
        let url = Self.resumeURL(for: key)
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private static func resumeURL(for key: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(NeuralVoiceStore.safeName(key)).resume")
    }

    /// Ask iOS to drop any task still fetching `key`'s model.
    func cancelDownloads(matching key: String) async {
        for task in await session.allTasks where Tag(task.taskDescription)?.key == key { task.cancel() }
    }

    func download(_ url: URL, key: String, to destination: URL) async throws {
        let task = savedResume(for: key).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: url)
        task.taskDescription = Tag(key: key, destination: destination).description
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                jobs[task.taskIdentifier] = Job(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let tag = Tag(downloadTask.taskDescription) else { return }
        // a few times a second is plenty for a progress ring
        let now = Date()
        lock.lock()
        let due = lastReport[downloadTask.taskIdentifier].map { now.timeIntervalSince($0) >= 0.4 } ?? true
        if due { lastReport[downloadTask.taskIdentifier] = now }
        lock.unlock()
        guard due else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in NeuralVoiceStore.shared.noteProgress(key: tag.key, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = Tag(downloadTask.taskDescription) else { return }
        var failure: Error?
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200, code != 206 {
            failure = NeuralVoiceStore.Failure.server(code)
        } else {
            // the system deletes the file when this returns
            do {
                try? FileManager.default.removeItem(at: tag.destination)
                try FileManager.default.moveItem(at: location, to: tag.destination)
            } catch {
                failure = error
            }
        }
        lock.lock()
        let waiting = jobs[downloadTask.taskIdentifier] != nil
        if waiting { jobs[downloadTask.taskIdentifier]?.failure = failure }
        lock.unlock()
        // no caller left to answer — the app is running only because iOS woke it for this,
        // so the store finishes the voice on its own
        if !waiting {
            Task { @MainActor in NeuralVoiceStore.shared.downloadLanded(key: tag.key, at: tag.destination, failure: failure) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tag = Tag(task.taskDescription)
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        lock.lock()
        lastReport[task.taskIdentifier] = nil
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        if let tag, let resume { resumeData[tag.key] = resume }
        lock.unlock()
        if let tag, let resume { try? resume.write(to: Self.resumeURL(for: tag.key)) }
        if let job {
            if let error {
                job.continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
            } else if let failure = job.failure {
                job.continuation.resume(throwing: failure)
            } else {
                job.continuation.resume()
            }
            return
        }
        // a task the app was relaunched under that broke on its own (a cancel was asked for, not news)
        guard let tag, let error, (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in NeuralVoiceStore.shared.downloadFailed(key: tag.key, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in NeuralVoiceStore.shared.backgroundEventsDone() }
    }
}
