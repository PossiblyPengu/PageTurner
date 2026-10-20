import AVFoundation
import MediaPlayer
import UIKit
import Combine

/// Audiobook playback on AVPlayer. One AVPlayer, items swapped manually on
/// track boundaries — simpler than AVQueuePlayer for backwards seeks across
/// tracks (the queue discards finished items).
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0   // seconds from book start
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var trackIndex = 0
    /// Chapters on the book's timeline — a file each for a multi-file book, the
    /// embedded markers for a single m4b. Empty when the audio has none.
    @Published private(set) var chapters: [AudioChapter] = []
    /// When it was paused, for the little rewind on playing again; and when an interruption took it away.
    private var pausedAt: Date?
    private var interruptedWhilePlaying: Date?

    @Published var rate: Float {
        didSet {
            if isPlaying { player?.rate = rate }
            UserDefaults.standard.set(Double(rate), forKey: "audioPlaybackRate")
            // and kept with this book: the next one starts at its own speed
            if abs((book.audioRate ?? 0) - Double(rate)) > 0.001 {
                library.mutate(book.id) { $0.audioRate = Double(rate) }
                book.audioRate = Double(rate)
            }
            updateNowPlaying()   // the lock screen's clock runs at this speed
            reaimSleepTimer()    // at 2× the boundary arrives twice as soon
        }
    }
    /// Seconds left on the sleep timer, nil when unset.
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var coverImage: UIImage?
    @Published var notice: String?
    /// True until `open()` has measured the files — Play does nothing before that.
    @Published private(set) var isLoading = true

    private var book: Book
    /// Places marked in this book, in the order they fall in it.
    @Published private(set) var clips: [AudioClip] = []
    private let library: LibraryStore
    private let urls: [URL]
    /// Serves the tracks streamed from Google Drive (nil when every track is on the phone).
    private var streamLoader: DriveStreamLoader?
    private var streamRefresh: Task<Void, Never>?
    private var streamRetries = 0
    private var player: AVPlayer?
    private var trackOffsets: [TimeInterval] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?
    /// A paused player lets the audio session go after a while — the task waits
    /// out the pause, then releases the route so nothing stays warm for hours.
    private var releaseSessionTask: Task<Void, Never>?
    private var sessionReleased = false
    private var lastSavedPosition: TimeInterval = -1
    private var lastChapterIndex: Int?
    private var artworkItem: MPMediaItemArtwork?
    /// Where and when this listen began, for the BookMaster session push.
    private var sessionStart: (at: Date, progression: Double)?
    /// Set once the files have been measured and the starting place found. Until then there is
    /// no position to save — an early close would have written "the start" over the real one.
    private var opened = false
    private var closed = false
    /// What was last written to the library, to tell a change from outside (a restart, a jump to
    /// BookMaster's place) from our own saves.
    private var checkpoint = PlaybackProgress()
    private var libraryChanges: AnyCancellable?
    /// Consecutive seconds the player said "paused" while we believed it was playing.
    private var stalledTicks = 0
    private var routeObserver: NSObjectProtocol?
    /// Watches the current item for a file that won't play.
    private var itemStatus: AnyCancellable?

    init(book: Book, library: LibraryStore) {
        self.book = book
        self.library = library
        // a Drive book that has not come down plays from the Drive: each part not on the phone is streamed
        let local = library.fileURLs(for: book)
        if let source = book.drive, source.parts.count == local.count {
            urls = zip(local, source.parts).map { file, part in
                FileManager.default.fileExists(atPath: file.path)
                    ? file : (DriveStreamLoader.url(file: part.id, size: part.size ?? 0, name: part.name) ?? file)
            }
        } else {
            urls = local
        }
        let saved = UserDefaults.standard.double(forKey: "audioPlaybackRate")
        // this book's own speed if it has one, else the last one used
        let own = book.audioRate ?? 0
        rate = own > 0 ? Float(own) : (saved > 0 ? Float(saved) : 1.0)
        clips = book.audioClips
        libraryChanges = library.$books.sink { [weak self] books in
            guard let self, !self.closed, let latest = books.first(where: { $0.id == self.book.id }) else { return }
            self.adopt(latest)
        }
    }

    var trackCount: Int { urls.count }
    var bookTitle: String { book.title }
    var bookAuthor: String { book.author }

    /// A sign-in token for the tracks streamed from Drive. They last an hour; another is fetched before then.
    private func refreshStreamToken() async {
        guard let token = try? await GoogleAuth.shared.accessToken() else { return }
        if let streamLoader { streamLoader.setToken(token) }
        else {
            streamLoader = DriveStreamLoader(token: token, refresh: {
                await MainActor.run { GoogleAuth.shared.discardAccessToken() }
                return try? await GoogleAuth.shared.accessToken()
            })
        }
    }

    /// An asset for a track: a file on the phone as it is, a Drive file through the loader that serves it.
    nonisolated private static func makeAsset(_ url: URL, loader: DriveStreamLoader?) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        if url.scheme == DriveStreamLoader.scheme, let loader {
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        }
        return asset
    }

    func open() async {
        // cumulative offsets turn "track i, t seconds" into a global position
        defer { isLoading = false }
        if urls.contains(where: { !$0.isFileURL }) {
            await refreshStreamToken()
            guard streamLoader != nil else {
                notice = "Sign in to Google Drive (Settings → Google Drive) to play this book without downloading it."
                return
            }
            streamRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 45 * 60 * 1_000_000_000)
                    await self?.refreshStreamToken()
                }
            }
        }
        let loader = streamLoader
        var offsets: [TimeInterval] = []
        var total: TimeInterval = 0
        // the files are measured side by side — a long mp3 book would take seconds one by one
        let measured: [TimeInterval?] = await withTaskGroup(of: (Int, TimeInterval?).self) { group in
            // a sliding window: a several-hundred-file book must not open every file at once
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let i = next, url = urls[next]
                next += 1
                group.addTask {
                    let d = try? await Self.makeAsset(url, loader: loader).load(.duration).seconds
                    return (i, d)
                }
            }
            for _ in 0 ..< min(8, urls.count) { addNext() }
            var out = [TimeInterval?](repeating: nil, count: urls.count)
            for await (i, d) in group {
                out[i] = d
                addNext()
            }
            return out
        }
        var unreadable: String?
        for (i, d) in measured.enumerated() {
            offsets.append(total)
            if let d, d.isFinite, d >= 0 { total += d } else if unreadable == nil { unreadable = trackNames[i] }
        }
        guard !closed else { return }
        if let unreadable { notice = "Couldn't read the length of \(unreadable). Its place in the book may be off." }
        trackOffsets = offsets
        duration = total
        chapters = urls.count > 1
            ? AudioChapters.fromTracks(titles: trackNames, offsets: offsets, duration: total)
            : await Self.embeddedChapters(of: urls.first, duration: total, loader: loader)
        guard !closed else { return }
        coverImage = library.cover(for: book)
        guard !urls.isEmpty else {
            notice = "No audio files found for this book."
            return
        }
        load(track: 0)
        let target = book.audioPosition ?? (book.progression.map { $0 * total }) ?? 0
        if target > 1 { seek(to: target, resume: false) }
        _ = checkpoint.adopt(position: book.audioPosition, progression: book.progression, playhead: position)
        opened = true
        configureSession()
        AudioFocus.shared.register("audiobook", pause: { [weak self] in self?.pause() }, remote: remoteHandlers)
        updateNowPlaying()
        // a call or alarm stops the audio — pause too, so the sitting ends there
        // instead of counting the interruption as listening
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    let wasPlaying = self.isPlaying
                    self.pause()
                    self.interruptedWhilePlaying = wasPlaying ? Date() : nil
                case .ended:
                    // a call, Siri or an alarm that is over: carry on, unless it has been so long that
                    // the reader has surely moved on (or anything else paused the book meanwhile)
                    defer { self.interruptedWhilePlaying = nil }
                    if options.contains(.shouldResume), let at = self.interruptedWhilePlaying,
                       Date().timeIntervalSince(at) < 300 {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.play()
                    }
                @unknown default: break
                }
            }
        }
        // headphones unplugged: iOS has already stopped the player — make the screen agree
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in self?.pause() }
        }
    }

    /// The library's record of this book changed from outside — a restart, "Go to N%" from
    /// BookMaster's offer — while the player was already loaded: follow it, rather than carry on
    /// from the old place and write that back over it.
    func adopt(_ latest: Book) {
        book = latest
        clips = latest.audioClips
        guard opened, duration > 0,
              checkpoint.adopt(position: latest.audioPosition, progression: latest.progression, playhead: position) else { return }
        let target = latest.audioPosition ?? (latest.progression.map { $0 * duration }) ?? 0
        sessionStart = nil
        if abs(target - position) > 2 { seek(to: target, resume: isPlaying) }
    }

    // MARK: - Voice boost and trimmed silence

    private let voiceTap = VoiceTap()
    private var trimTimer: Timer?

    /// Put the processing tap on `item` when either switch is on (and take it off when both are off).
    private func applyVoiceTap(to item: AVPlayerItem) {
        let boost = AppPrefs.audioVoiceBoost, trim = AppPrefs.audioTrimSilence
        voiceTap.state.dsp.boost = boost
        voiceTap.state.dsp.trim = trim
        guard boost || trim else {
            item.audioMix = nil
            stopTrimTimer()
            return
        }
        Task { [weak self, weak item] in
            guard let item else { return }
            let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            guard let track = tracks.first, let self, !self.closed, item === self.player?.currentItem else { return }
            item.audioMix = self.voiceTap.makeMix(for: track)
        }
        if trim { startTrimTimer() } else { stopTrimTimer() }
    }

    /// The switches changed: apply them to what is playing now.
    func refreshVoiceTap() {
        guard let item = player?.currentItem else { return }
        applyVoiceTap(to: item)
        if !AppPrefs.audioTrimSilence, isPlaying { player?.rate = rate }
    }

    /// While quiet, the player runs faster than the chosen speed; speech brings it back.
    private func startTrimTimer() {
        guard trimTimer == nil else { return }
        trimTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, let player = self.player else { return }
                let wanted = self.voiceTap.state.inSilence ? min(self.rate * 2.5, 4) : self.rate
                if abs(player.rate - wanted) > 0.01 { player.rate = wanted }
            }
        }
    }

    private func stopTrimTimer() {
        trimTimer?.invalidate()
        trimTimer = nil
    }

    // MARK: - Marks

    private func reloadClips() {
        if let latest = library.books.first(where: { $0.id == book.id }) { book = latest }
        clips = book.audioClips.sorted { $0.time < $1.time }
    }

    /// Mark the place being played, with a note if there is one.
    func addClip(note: String = "") {
        let clip = AudioClip(time: position, chapter: currentChapter?.title, note: note)
        library.mutate(book.id) { $0.audioClips.append(clip) }
        reloadClips()
    }

    func setClipNote(_ id: UUID, note: String) {
        library.mutate(book.id) { stored in
            if let i = stored.audioClips.firstIndex(where: { $0.id == id }) { stored.audioClips[i].note = note }
        }
        reloadClips()
    }

    func removeClip(_ id: UUID) {
        library.mutate(book.id) { $0.audioClips.removeAll { $0.id == id } }
        reloadClips()
    }

    func goToClip(_ clip: AudioClip) {
        seek(to: clip.time, resume: isPlaying)
    }

    /// What the lock screen, headset and Control Center buttons do while this owns them.
    private var remoteHandlers: RemoteControls.Handlers {
        RemoteControls.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.skipForwardAChapter() },
            previous: { [weak self] in self?.skipBackAChapter() },
            skipForward: { [weak self] in self?.skip(by: AppPrefs.skipForward) },
            skipBackward: { [weak self] in self?.skip(by: -AppPrefs.skipBack) },
            seekTo: { [weak self] t in self?.seek(to: t, resume: self?.isPlaying ?? false) },
            setRate: { [weak self] r in self?.rate = r },
            refresh: { [weak self] in self?.updateNowPlaying() })
    }

    private func load(track index: Int) {
        guard urls.indices.contains(index) else { return }
        pausedAt = nil
        trackIndex = index
        let item = AVPlayerItem(asset: Self.makeAsset(urls[index], loader: streamLoader))
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed, let self, let item else { return }
                MainActor.assumeIsolated {
                    guard !self.closed else { return }
                    // a stream that was refused (its token ran out part way through a long file) is asked for again with
                    // a fresh one, from where it was
                    if !self.urls[index].isFileURL, self.streamRetries < 2 {
                        self.streamRetries += 1
                        let wasPlaying = self.isPlaying
                        let at = max(0, self.position - self.trackOffsets[index])
                        Task { @MainActor in
                            await self.refreshStreamToken()
                            guard !self.closed else { return }
                            self.load(track: index)
                            await self.player?.seek(to: CMTime(seconds: at, preferredTimescale: 600))
                            if wasPlaying { self.resumePlayback() }
                        }
                        return
                    }
                    let code = (item.error as NSError?).map { " (\($0.domain) \($0.code))" } ?? ""
                    let why = (item.error?.localizedDescription ?? "unreadable file") + code
                    Log.error("audio", "\(self.trackNames[index]) would not play: \(why) — \(self.urls[index].isFileURL ? "file" : "stream")")
                    self.notice = "Couldn't play \(self.trackNames[index]): \(why)"
                    self.pause()
                }
            }
        if let player { player.replaceCurrentItem(with: item) } else { player = AVPlayer(playerItem: item) }
        applyVoiceTap(to: item)
        position = trackOffsets[index]
        observeEnd(of: item)
        updateNowPlaying()
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        // advance synchronously on the main queue it already arrives on: a Task
        // hop leaves a gap where the item has ended (player reads .paused) but
        // nothing has loaded the next file — the stalled-tick watchdog can see it
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func advance() {
        let next = trackIndex + 1
        guard next < urls.count else {
            // finished: clamp at the end, persist, stop
            pause()
            position = duration
            savePosition(force: true)
            return
        }
        load(track: next)
        if isPlaying { resumePlayback() }
    }

    // MARK: - Controls

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player != nil else { return }
        // a file that failed to load never recovers by itself: a fresh item is the retry
        // (a file that still cannot play reports it again through the status watcher)
        if player?.currentItem?.status == .failed {
            let keep = position
            load(track: trackIndex)
            seek(to: keep, resume: false)
        }
        player?.volume = 1
        // pressing play on a book that has finished starts it again
        if duration > 0, position >= duration - 0.5 { seek(to: 0, resume: false) }
        // after a break, a little back from where it stopped (never before the start of the chapter)
        if let at = pausedAt {
            pausedAt = nil
            let back = AudioChapters.smartRewind(pausedFor: Date().timeIntervalSince(at))
            if back > 0, duration > 0, position < duration - 0.5 {
                let floor = chapters.count > 1 ? (AudioChapters.index(at: position, in: chapters).map { chapters[$0].start } ?? 0) : 0
                seek(to: max(position - back, floor), resume: false)
            }
        }
        AudioFocus.shared.claim("audiobook")
        releaseSessionTask?.cancel()
        if sessionReleased { configureSession(); sessionReleased = false }
        if sessionStart == nil, duration > 0 { sessionStart = (Date(), position / duration) }
        resumePlayback()
        isPlaying = true
        reaimSleepTimer()   // a pause froze the playhead — the chapter deadline is stale
        startTimeObserver()
        MPNowPlayingInfoCenter.default().playbackState = .playing
        updateNowPlaying()
    }

    /// `play()` resets rate to `defaultRate` — reapply the user's speed.
    private func resumePlayback() {
        player?.play()
        player?.rate = rate
    }

    func pause() {
        let wasPlaying = isPlaying
        if wasPlaying { pausedAt = Date() }
        interruptedWhilePlaying = nil   // anything but an interruption's own pause cancels carrying on afterwards
        player?.pause()
        player?.volume = 1
        isPlaying = false
        stalledTicks = 0
        // pausing what was not playing (another audio source claiming focus) is not a listen:
        // saving would re-stamp lastOpenedAt and make "Continue" offer this book
        guard wasPlaying else { armSessionRelease(); return }
        savePosition(force: true)
        endBookMasterSession()
        MPNowPlayingInfoCenter.default().playbackState = .paused
        updateNowPlaying()   // the clock stops, and the lock screen should say so
        armSessionRelease()
    }

    /// A paused player does not need the route held warm: after ten quiet
    /// minutes, hand the session back — but only when nobody else (read-aloud)
    /// is speaking through it. `play()` puts it back.
    private func armSessionRelease() {
        releaseSessionTask?.cancel()
        releaseSessionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled, let self, !self.isPlaying,
                  AudioFocus.shared.soleOwner("audiobook") else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.sessionReleased = true
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: position + seconds, resume: isPlaying)
    }

    /// Global position seek — crosses track boundaries when needed.
    func seek(to target: TimeInterval, resume: Bool) {
        guard !trackOffsets.isEmpty else { return }
        pausedAt = nil   // a deliberate move is not a place to be stepped back from
        let t = min(max(target, 0), duration)
        let track = AudioChapters.trackIndex(at: t, offsets: trackOffsets) ?? trackIndex
        if track != trackIndex { load(track: track) }
        let local = t - trackOffsets[track]
        player?.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        position = t
        if resume { resumePlayback() }
        updateNowPlaying()
        reaimSleepTimer()   // the playhead moved — the chapter boundary moved with it
    }

    /// Chapters when the book has them, otherwise files.
    func skipForwardAChapter() {
        if chapters.count > 1 { nextChapter() } else { nextTrack() }
    }

    func skipBackAChapter() {
        if chapters.count > 1 { previousChapter() } else { previousTrack() }
    }

    func nextTrack() {
        goToTrack(trackIndex + 1)
    }

    func previousTrack() {
        // restart the track unless we're already at its head
        if position - trackOffsets[trackIndex] > 3 {
            seek(to: trackOffsets[trackIndex], resume: isPlaying)
        } else {
            goToTrack(trackIndex - 1)
        }
    }

    /// Jump to a track (chapter picker / next / previous).
    func goToTrack(_ index: Int) {
        guard urls.indices.contains(index), index != trackIndex else { return }
        let wasPlaying = isPlaying
        load(track: index)
        if wasPlaying { resumePlayback() }
    }

    // MARK: - Chapters

    var currentChapterIndex: Int? { AudioChapters.index(at: position, in: chapters) }

    var currentChapter: AudioChapter? { currentChapterIndex.map { chapters[$0] } }

    /// Seconds left in the chapter being played.
    var chapterRemaining: TimeInterval? {
        currentChapter.map { max($0.end - position, 0) }
    }

    func goToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        seek(to: chapters[index].start, resume: isPlaying)
    }

    func nextChapter() {
        guard let current = currentChapterIndex, current + 1 < chapters.count else { return }
        goToChapter(current + 1)
    }

    /// Restart the chapter, or go back one when already at its head.
    func previousChapter() {
        guard let target = AudioChapters.previousTarget(position: position, in: chapters) else { return }
        goToChapter(target)
    }

    /// The markers inside a single audio file (m4b/m4a chapter tracks). A file
    /// without any, or one that won't say, has no chapters.
    private static func embeddedChapters(of url: URL?, duration: TimeInterval, loader: DriveStreamLoader? = nil) async -> [AudioChapter] {
        guard let url else { return [] }
        let asset = makeAsset(url, loader: loader)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages), !groups.isEmpty
        else { return [] }
        var raw: [(title: String, start: TimeInterval, end: TimeInterval?)] = []
        for group in groups {
            let titles = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
            var title = ""
            if let item = titles.first ?? group.items.first, let text = try? await item.load(.stringValue) {
                title = text
            }
            let end = group.timeRange.end.seconds
            raw.append((title, group.timeRange.start.seconds, end.isFinite ? end : nil))
        }
        return AudioChapters.normalise(raw, duration: duration)
    }

    var trackNames: [String] {
        if book.trackTitles.count == urls.count { return book.trackTitles }
        // the files are stored under internal names — never show those
        return urls.indices.map { "Part \($0 + 1)" }
    }

    // MARK: - Sleep timer

    /// In chapter-end mode the deadline is re-aimed at the boundary by whatever
    /// can move it (seek, rate, a resume after a pause) — the bell itself is
    /// rung once, exactly on the boundary, instead of a poll every 15 seconds.
    private var sleepAtChapterEnd = false

    func setSleepTimer(minutes: Int?) {
        sleepAtChapterEnd = false
        player?.volume = 1   // a fade in progress ends with the timer
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes, minutes > 0 else {
            sleepDeadline = nil
            sleepRemaining = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepRemaining = sleepDeadline?.timeIntervalSinceNow
        armSleepTimer()
    }

    /// "Stop at the end of this chapter" — the same countdown, aimed at the
    /// chapter boundary rather than a wall-clock length.
    func setSleepTimerToChapterEnd() {
        guard chapterEnd != nil else { return }
        sleepAtChapterEnd = true
        reaimSleepTimer()
    }

    /// One bell, rung once. No tolerance to coalesce against: the boundary is
    /// the point, and a single wakeup per timer is already cheap.
    private func armSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let deadline = sleepDeadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sleepTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    /// Chapter mode's wall clock moves with the playhead — the only deadline a
    /// seek, a rate change or a resume can shift. Minute mode is absolute and
    /// needs no re-aim (re-arming it at the same deadline is a harmless no-op).
    private func reaimSleepTimer() {
        if sleepAtChapterEnd, let end = chapterEnd {
            sleepDeadline = Date().addingTimeInterval(
                SleepTiming.wall(remainingMedia: end - position, rate: Double(rate)))
        }
        armSleepTimer()
        sleepRemaining = sleepDeadline?.timeIntervalSinceNow
    }

    /// Where the chapter being played ends — nil for a book without chapters.
    private var chapterEnd: TimeInterval? {
        guard chapters.count > 1, let i = currentChapterIndex else { return nil }
        return i + 1 < chapters.count ? chapters[i + 1].start : duration
    }

    private func sleepTimerFired() {
        sleepTimer = nil
        guard let deadline = sleepDeadline else { return }
        // Paused in chapter mode: the boundary cannot drift nearer while the
        // playhead is still — leave the bell set for play() to re-aim.
        guard SleepTiming.shouldPause(now: Date(), deadline: deadline,
                                      isPlaying: isPlaying, chapterMode: sleepAtChapterEnd)
        else { return }
        // pause while the fade is still down: clearing the timer first would snap the volume up for an instant
        pause()
        setSleepTimer(minutes: nil)
    }

    // MARK: - Teardown

    /// Persist and release — call from the view's onDisappear.
    func close() {
        streamRefresh?.cancel()
        stopTrimTimer()
        savePosition()
        pause()
        releaseSessionTask?.cancel()
        releaseSessionTask = nil
        closed = true
        libraryChanges?.cancel()
        AudioFocus.shared.unregister("audiobook")   // the lock-screen buttons pass on, or are cleared
        setSleepTimer(minutes: nil)
        itemStatus?.cancel()
        itemStatus = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func savePosition(force: Bool = false) {
        // before the files are measured there is no place to save; after a close there is nothing to follow
        guard opened, !closed, duration > 0, position.isFinite, checkpoint.maySave(at: position) else { return }
        let progression = position / duration
        guard progression.isFinite else { return }
        checkpoint.saved(position: position, progression: progression)
        // the record as it is now: an edit made while this was loaded (a title, a shelf) must survive
        library.mutate(book.id) { stored in
            stored.audioPosition = position
            stored.progression = progression
            stored.lastOpenedAt = Date()
        }
        if let latest = library.books.first(where: { $0.id == book.id }) { book = latest }
        let ref = book.bookMasterRef
        Task {
            await BookMaster.shared.syncProgress(
                bookKey: book.id.uuidString, ref: ref, percent: progression, isAudio: true, force: force,
                pinned: { [weak self] id in self?.pin(id) })
        }
    }

    private func pin(_ id: String) {
        guard book.bookmasterId != id else { return }
        book.bookmasterId = id
        library.updateBookMaster(book.id) { $0.bookmasterId = id }
    }

    /// Tell BookMaster how far this listen got. Under half a percent is not a session.
    private func endBookMasterSession() {
        guard let start = sessionStart, duration > 0 else { return }
        sessionStart = nil
        let end = position / duration
        let minutes = Date().timeIntervalSince(start.at) / 60
        let moved = (end - start.progression) * 100 >= 0.5
        // the local log keeps any real listen — even a long one that went nowhere
        if moved || minutes >= 2 {
            ReadingLog.shared.record(book: book, minutes: minutes, from: start.progression, to: end, audio: true)
        }
        guard moved else { return }
        let ref = book.bookMasterRef
        Task {
            await BookMaster.shared.syncSession(
                ref: ref, percentStart: start.progression, percentEnd: end,
                minutes: minutes, at: Date())
        }
    }

    // MARK: - Plumbing

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.error("audio", "session setup failed: \(error.localizedDescription)")
        }
    }

    private func startTimeObserver() {
        guard timeObserver == nil else { return }
        // already delivered on the main queue — no task hop per second
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard time.isNumeric, time.seconds.isFinite, self.trackOffsets.indices.contains(self.trackIndex) else { return }
                self.position = self.trackOffsets[self.trackIndex] + time.seconds
                if let deadline = self.sleepDeadline {
                    let left = max(0, deadline.timeIntervalSinceNow)
                    self.sleepRemaining = left
                    // ease the sound out over the last ten seconds
                    if self.isPlaying { self.player?.volume = left < 10 ? Float(max(0.1, left / 10)) : 1 }
                }
                // the lock screen shows the chapter's name — keep it current
                if self.currentChapterIndex != self.lastChapterIndex {
                    self.lastChapterIndex = self.currentChapterIndex
                    self.updateNowPlaying()
                }
                // iOS paused the player under us (an unplugged headset, another app's audio) and nobody told us
                if self.isPlaying, self.player?.timeControlStatus == .paused {
                    self.stalledTicks += 1
                    if self.stalledTicks >= 2 { self.pause() }
                } else {
                    self.stalledTicks = 0
                }
                // persist about every 10s so resume survives a force-quit
                if self.isPlaying, abs(self.position - self.lastSavedPosition) >= 10 {
                    self.lastSavedPosition = self.position
                    self.savePosition()
                }
            }
        }
    }

    private func updateNowPlaying() {
        if artworkItem == nil, let image = library.cover(for: book) {
            artworkItem = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? book.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
        ]
        if let artworkItem { info[MPMediaItemPropertyArtwork] = artworkItem }
        if let index = currentChapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = index
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
