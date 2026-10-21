import SwiftUI

/// The full player: cover-tinted backdrop, big art, a seek bar, and the
/// transport controls as one glass cluster. It fills the Reading tab while an
/// audiobook plays — the mini player stands in everywhere else.
struct NowPlayingView: View {
    @ObservedObject var player: AudioPlayer
    @Environment(AppRouter.self) private var router
    let onStop: () -> Void
    /// The way off the player: the Reading tab is its home, so leaving is a tab switch.
    let onClose: () -> Void
    @State private var scrubbing: TimeInterval?
    @AppStorage("audio-skip-back") private var skipBack = 15.0
    @AppStorage("audio-skip-fwd") private var skipFwd = 30.0
    @State private var tint: Color = .ptAccent
    @State private var showChapters = false
    @State private var showClips = false
    @AppStorage("audio-voice-boost") private var voiceBoost = false
    @AppStorage("audio-trim-silence") private var trimSilence = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var shownPosition: TimeInterval { scrubbing ?? player.position }

    /// The chapter at the place the bar is showing — which is somewhere else while the thumb is dragged.
    private var shownChapter: AudioChapter? {
        AudioChapters.index(at: shownPosition, in: player.chapters).map { player.chapters[$0] }
    }

    /// "1x", "1.25x", "1.5x" — `%.2g` would round 1.25 to "1.2".
    private func speedLabel(_ rate: Double) -> String { String(format: "%.3gx", rate) }

    /// Everything under the top bar. When it is taller than the screen (landscape, large text) it scrolls.
    private var stack: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            // landscape and accessibility text sizes have no height to spare for the art
            if verticalSizeClass != .compact, !typeSize.isAccessibilitySize {
                artwork
                Spacer(minLength: 8)
            }
            titles
            Spacer(minLength: 8)
            scrubber
            transport
            extras
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ViewThatFits(in: .vertical) {
                stack
                ScrollView { stack }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.bottom, 12)
        .ptReadableWidth(560)
        .background(backdrop)
        .onAppear { BookMaster.shared.place = "player" }
        .onDisappear { BookMaster.shared.place = "library" }
        #if DEBUG
        // CI simulator run: show the chapter list (Debug/DebugScenario.swift)
        .task {
            guard UserDefaults.standard.string(forKey: "PTDebugPlayerSheet") == "chapters" else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showChapters = true
        }
        #endif
        .task(id: player.coverImage == nil) {
            if let color = player.coverImage?.averageColor { tint = Color(color) }
        }
        .onChange(of: voiceBoost) { _, _ in player.refreshVoiceTap() }
        .onChange(of: trimSilence) { _, _ in player.refreshVoiceTap() }
        .sheet(isPresented: $showClips) {
            ClipListSheet(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Pageturner", isPresented: Binding(
            get: { player.notice != nil },
            set: { if !$0 { player.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.notice ?? "")
        }
    }

    // MARK: Pieces

    private var backdrop: some View {
        LinearGradient(
            colors: [tint.opacity(0.55), tint.opacity(0.18), Color(.systemBackground)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            PTIconButton(systemImage: "chevron.down", label: "Close player") { onClose() }
            Spacer()
            Menu {
                if player.chapters.count > 1 {
                    Button { showChapters = true } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                }
                Button { router.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Label("Stop and Close", systemImage: "stop.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .ptGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var artwork: some View {
        Group {
            if let cover = player.coverImage {
                // the jacket's own shape — m4b art is often square but fetched
                // covers are 2:3, and a forced square crop cut them short
                Image(uiImage: cover).resizable().scaledToFit()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.ptAccent.opacity(0.8), .brown],
                        startPoint: .top, endPoint: .bottom)
                    Image(systemName: "headphones")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: 300, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: tint.opacity(player.isPlaying ? 0.5 : 0.2), radius: player.isPlaying ? 30 : 12, y: player.isPlaying ? 14 : 6)
        .scaleEffect(player.isPlaying ? 1 : 0.88)
        .ptAnimation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
        .padding(.horizontal, 40)
        .accessibilityHidden(true)
    }

    private var titles: some View {
        VStack(spacing: 4) {
            Text(player.bookTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !player.bookAuthor.isEmpty {
                Text(player.bookAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let chapter = shownChapter, player.chapters.count > 1 {
                Text(chapter.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { shownPosition }, set: { scrubbing = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target, resume: player.isPlaying)
                        scrubbing = nil
                    }
                }
            )
            .tint(.ptAccent)
            .accessibilityLabel("Position")
            .accessibilityValue("\(format(shownPosition)) of \(format(player.duration))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.skip(by: skipFwd)
                case .decrement: player.skip(by: -skipBack)
                @unknown default: break
                }
            }
            HStack {
                Text(format(shownPosition)).monospacedDigit()
                Spacer()
                Text("-" + format(max(player.duration - shownPosition, 0))).monospacedDigit()
            }
            if let chapter = shownChapter, player.chapters.count > 1 {
                // its own line: at large text sizes it used to share a row with
                // the remaining time and wrap onto it
                Text("\(format(max(chapter.end - shownPosition, 0))) left in chapter")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
    }

    private var transport: some View {
        let chapterSkips = player.chapters.count > 1
        return PTGlassGroup(spacing: 14) {
            HStack(spacing: chapterSkips ? 10 : 18) {
                if chapterSkips {
                    transportButton("backward.end.fill", label: "Previous chapter", size: 50) {
                        player.previousChapter()
                    }
                }
                transportButton("gobackward.\(Int(skipBack))", label: "Back \(Int(skipBack)) seconds", size: chapterSkips ? 56 : 64) {
                    player.skip(by: -skipBack)
                }
                Button { player.togglePlay() } label: {
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .ptSymbolSwap(on: player.isPlaying)
                        }
                    }
                    .frame(width: 88, height: 88)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(player.isLoading)
                .ptGlass(in: Circle(), tint: .ptAccent.opacity(0.55), interactive: true)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                transportButton("goforward.\(Int(skipFwd))", label: "Forward \(Int(skipFwd)) seconds", size: chapterSkips ? 56 : 64) {
                    player.skip(by: skipFwd)
                }
                if chapterSkips {
                    transportButton("forward.end.fill", label: "Next chapter", size: 50) {
                        player.nextChapter()
                    }
                }
            }
        }
        .padding(.vertical, 18)
    }

    private func transportButton(
        _ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .ptGlass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }

    private var extras: some View {
        PTGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                Menu {
                    Section("Sound") {
                        Toggle("Voice boost", isOn: $voiceBoost)
                        Toggle("Trim silence", isOn: $trimSilence)
                    }
                    Section("Speed") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                        Button { player.rate = Float(rate) } label: {
                            if abs(Double(player.rate) - rate) < 0.01 {
                                Label(speedLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(speedLabel(rate))
                            }
                        }
                    }
                    }
                } label: {
                    chip(speedLabel(Double(player.rate)), symbol: "speedometer")
                        .ptNumberRoll(on: player.rate)
                }
                .accessibilityLabel("Playback speed")

                Menu {
                    Button("Off") { player.setSleepTimer(minutes: nil) }
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                    }
                    if player.chapters.count > 1 {
                        Button("End of chapter") { player.setSleepTimerToChapterEnd() }
                    }
                } label: {
                    if let left = player.sleepRemaining {
                        chip("\(Int(left / 60) + 1)m", symbol: "moon.fill")
                    } else {
                        chip("Sleep", symbol: "moon")
                    }
                }
                .accessibilityLabel("Sleep timer")

                if player.chapters.count > 1 {
                    Button { showChapters = true } label: {
                        chip("Chapters", symbol: "list.bullet")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chapters")
                }

                Menu {
                    Button { player.addClip() } label: {
                        Label("Mark This Place", systemImage: "bookmark")
                    }
                    if !player.clips.isEmpty {
                        Button { showClips = true } label: {
                            Label("Show Marks (\(player.clips.count))", systemImage: "list.bullet")
                        }
                    }
                } label: {
                    chip(player.clips.isEmpty ? "Mark" : "Marks", symbol: "bookmark")
                }
                .accessibilityLabel("Marks")
                .sensoryFeedback(.success, trigger: player.clips.count) { old, new in new > old }
            }
        }
    }

    /// A glass pill with an icon and a word; just the icon once the text is large
    /// enough that three words won't fit in a row (each control has its own VoiceOver label).
    private func chip(_ text: String, symbol: String) -> some View {
        Group {
            if typeSize >= .xxxLarge {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(minWidth: 56, minHeight: 48)
            } else {
                Label(text, systemImage: symbol)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16)
                    .frame(height: 40)
            }
        }
        .foregroundStyle(.primary)
        .ptGlassCapsule(interactive: true)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, r)
            : String(format: "%d:%02d", m, r)
    }
}

/// Every chapter with where it starts; tap one to jump there.
private struct ChapterListSheet: View {
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters) { chapter in
                    let current = chapter.id == player.currentChapterIndex
                    Button {
                        player.goToChapter(chapter.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .font(.body.weight(current ? .semibold : .regular))
                                    .foregroundStyle(current ? Color.ptAccent : Color.primary)
                                    .lineLimit(2)
                                Text(Self.format(chapter.length))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if current {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundStyle(Color.ptAccent)
                                    .accessibilityHidden(true)
                            }
                            Text(Self.format(chapter.start))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(chapter.id)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
                .listStyle(.plain)
                .onAppear {
                    if let index = player.currentChapterIndex { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, r)
            : String(format: "%d:%02d", m, r)
    }
}


/// The places marked in an audiobook: tap to go there, add a note, swipe to remove.
private struct ClipListSheet: View {
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(player.clips) { clip in
                    ClipRow(clip: clip,
                            onGo: { player.goToClip(clip); dismiss() },
                            onNote: { player.setClipNote(clip.id, note: $0) })
                }
                .onDelete { offsets in
                    for index in offsets { player.removeClip(player.clips[index].id) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if player.clips.isEmpty {
                    ContentUnavailableView(
                        "No Marks", systemImage: "bookmark",
                        description: Text("Use Mark in the player to keep your place with a note."))
                }
            }
            .navigationTitle("Marks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ClipRow: View {
    let clip: AudioClip
    let onGo: () -> Void
    let onNote: (String) -> Void
    @State private var note: String

    init(clip: AudioClip, onGo: @escaping () -> Void, onNote: @escaping (String) -> Void) {
        self.clip = clip
        self.onGo = onGo
        self.onNote = onNote
        _note = State(initialValue: clip.note)
    }

    private var time: String {
        let s = Int(clip.time.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onGo) {
                HStack {
                    Text(time).font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(Color.ptAccent)
                    if let chapter = clip.chapter {
                        Text(chapter).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(time)")
            TextField("Add a note", text: $note, axis: .vertical)
                .font(.callout)
                .lineLimit(1...4)
                .onSubmit { onNote(note) }
                // and when the row goes away (the sheet closing), so a note is never lost
                .onDisappear { if note != clip.note { onNote(note) } }
        }
        .padding(.vertical, 2)
    }
}
