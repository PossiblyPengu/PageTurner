import SwiftUI
import UIKit

/// Every voice there is for reading aloud — the ones iOS ships with, and neural voices that can
/// be downloaded — by language, with a sample button on each. Used by Settings and by the reader
/// (the Reading sheet and the read-aloud bar).
struct VoiceListView: View {
    /// The chosen voice's identifier; nil is Automatic.
    @Binding var selection: String?
    /// How fast the samples are spoken.
    let rate: Double

    private enum Source: Hashable {
        case device, neural
    }

    @State private var source: Source
    @State private var voices: [SpeechVoice] = []
    @State private var looked = false
    @State private var query = ""
    /// A neural voice to choose, or to hear, as soon as its download is done.
    @State private var chooseWhenReady: String?
    @State private var playWhenReady: String?
    @ObservedObject private var preview = SpeechPreview.shared
    private let store = NeuralVoiceStore.shared

    init(selection: Binding<String?>, rate: Double) {
        _selection = selection
        self.rate = rate
        var neural = selection.wrappedValue.flatMap(NeuralVoice.key(fromID:)) != nil
        #if DEBUG
        if DebugScenario.voiceSource == "neural" { neural = true }
        #endif
        _source = State(initialValue: neural ? .neural : .device)
    }

    var body: some View {
        following(chrome(list))
    }

    private var list: some View {
        List {
            sourcePicker
            switch source {
            case .device: deviceRows
            case .neural: neuralRows
            }
        }
        .ptSoftScrollEdges()
    }

    private func chrome<V: View>(_ content: V) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query, prompt: source == .device ? "Search voices" : "Search neural voices")
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.ptAccent)
    }

    /// Loading, and the downloads the list is waiting on.
    private func following<V: View>(_ content: V) -> some View {
        content
            .task { await load() }
            // coming back from iOS Settings after downloading a voice
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await load() }
            }
            // auditioning voices goes with a quiet book: narration holds (not stops) while
            // this screen is up — the samples and the speaking voice never overlap
            .onAppear { AudioFocus.shared.pauseAll() }
            .onDisappear { preview.stop() }
            .onChange(of: source) { _, _ in
                preview.stop()
                query = ""
            }
            .onChange(of: store.installed.count) { _, _ in installedChanged() }
            .onChange(of: store.progress.count) { _, _ in transfersChanged() }
    }

    private var sourcePicker: some View {
        Section {
            Picker("Voices", selection: $source) {
                Text("Device").tag(Source.device)
                Text("Neural").tag(Source.neural)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: Device voices

    @ViewBuilder
    private var deviceRows: some View {
        let groups = SpeechVoices.groups(
            voices, query: query, preferred: Locale.preferredLanguages,
            languageName: Self.languageName, regionName: Self.regionName)
        if query.isEmpty { automatic }
        if query.isEmpty && looked && !voices.isEmpty && SpeechVoices.betterVoiceCount(in: voices) == 0 { betterVoices }
        if voices.isEmpty && looked {
            none
        } else {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.voices) { row($0) }
                }
            }
        }
        if !query.isEmpty && groups.isEmpty && !voices.isEmpty {
            ContentUnavailableView.search(text: query)
        }
        more
    }

    private var automatic: some View {
        Section {
            HStack(spacing: 8) {
                Button { selection = nil } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic").foregroundStyle(.primary)
                            Text("The best voice installed for each book’s language")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if selection == nil { chosenMark }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                sampleButton(nil)
            }
        }
    }

    /// Shown while only the basic voices are installed: how to get the natural ones.
    private var betterVoices: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Only the basic voices are installed", systemImage: "waveform")
                    .font(.headline)
                Text("iOS has Premium and Enhanced voices that sound far more natural. To add one, open Settings → Accessibility → Spoken Content → Voices, choose a language and a voice (Premium is the best), and tap the download button. It shows up here when you come back.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Or choose a Neural voice, which downloads inside Pageturner.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Choose a Neural Voice") { source = .neural }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        }
    }

    private var none: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("No voices found", systemImage: "waveform.slash")
                    .font(.headline)
                Text("iOS hasn’t listed any voices yet. Give it a moment and look again — and if there are still none, add one under Settings → Accessibility → Spoken Content → Voices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Look Again") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        }
    }

    private var more: some View {
        Section {
            Text("Enhanced and Premium voices sound far more natural. To add one, open Settings → Accessibility → Spoken Content → Voices (Read & Speak on newer iOS), choose a language and voice, and tap the download button. It appears here the next time you come back. iOS decides which of Siri’s voices apps may use; any it offers is marked Siri here. For speech closer to that, choose Neural above — those voices download inside Pageturner and run on this iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ voice: SpeechVoice) -> some View {
        HStack(spacing: 8) {
            Button { selection = voice.id } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.displayName).foregroundStyle(.primary)
                        Text(detail(voice))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ForEach(voice.badges, id: \.self) { badge in
                        QualityBadge(text: badge, premium: badge != "Enhanced")
                    }
                    if selection == voice.id { chosenMark }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selection == voice.id ? .isSelected : [])
            sampleButton(voice)
        }
        // what iOS calls the voice, for telling someone which voices a phone lists
        .contextMenu {
            Button { UIPasteboard.general.string = voice.id } label: {
                Label("Copy Voice ID", systemImage: "doc.on.doc")
            }
        }
    }

    /// "United States", or the language tag when the voice has no region.
    private func detail(_ voice: SpeechVoice) -> String {
        SpeechVoices.region(voice.language).flatMap(Self.regionName) ?? voice.language
    }

    // MARK: Neural voices

    @ViewBuilder
    private var neuralRows: some View {
        let groups = SpeechVoices.groups(
            store.catalog.voices, query: query, preferred: Locale.preferredLanguages,
            languageName: Self.languageName, regionName: Self.regionName)
        if query.isEmpty { neuralNote }
        ForEach(groups) { group in
            Section(group.title) {
                ForEach(group.voices) { neuralRow($0) }
            }
        }
        if !query.isEmpty && groups.isEmpty {
            ContentUnavailableView.search(text: query)
        }
        if !store.installed.isEmpty {
            Section {
                NavigationLink {
                    SavedVoicesView(selection: $selection)
                } label: {
                    LabeledContent("Saved Voices", value: NeuralVoiceSummary.text(for: store))
                }
            }
        }
    }

    private var neuralNote: some View {
        Section {
            Text("Neural voices sound more natural and keep reading with the screen locked. Choosing one downloads it once (the size is shown on each) and keeps it on this iPhone, so it works offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func neuralRow(_ voice: NeuralVoice) -> some View {
        let installed = store.isInstalled(voice)
        let transfer = store.progress[voice.key]
        let chosen = selection == voice.id
        return HStack(spacing: 8) {
            Button { choose(voice) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.displayName).foregroundStyle(.primary)
                        Text(neuralDetail(voice))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if transfer == nil, let failure = store.failures[voice.key] {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 8)
                    neuralStatus(installed: installed, transfer: transfer, chosen: chosen)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if transfer == nil {
                neuralSampleButton(voice, installed: installed)
            } else {
                Button { cancel(voice) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if installed {
                Button(role: .destructive) { remove(voice) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func neuralStatus(installed: Bool, transfer: NeuralVoiceStore.Transfer?, chosen: Bool) -> some View {
        if let transfer {
            HStack(spacing: 6) {
                if transfer.phase == .downloading {
                    Text("\(Int((transfer.fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.circular)
                } else {
                    Text(transfer.phase == .checking ? "Checking" : "Preparing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        } else if installed {
            if chosen { chosenMark }
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(Color.ptAccent)
                .accessibilityLabel("Download")
        }
    }

    private func neuralSampleButton(_ voice: NeuralVoice, installed: Bool) -> some View {
        let playing = preview.playing == voice.id
        return Button {
            if installed {
                preview.toggle(voice, rate: rate)
            } else {
                // downloaded first, then heard
                playWhenReady = voice.key
                store.install(voice)
            }
        } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(Color.ptAccent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(playing ? "Stop sample" : installed ? "Hear \(voice.displayName)" : "Download and hear \(voice.displayName)")
    }

    /// "Medium · United States · 63 MB".
    private func neuralDetail(_ voice: NeuralVoice) -> String {
        let place = SpeechVoices.region(voice.language).flatMap(Self.regionName) ?? voice.country
        return [voice.quality.label, place, voice.sizeLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Choose an installed voice; one that isn't yet is downloaded and then chosen.
    private func choose(_ voice: NeuralVoice) {
        if store.isInstalled(voice) {
            selection = voice.id
        } else if !store.isBusy(voice) {
            chooseWhenReady = voice.key
            store.install(voice)
        }
    }

    private func cancel(_ voice: NeuralVoice) {
        if chooseWhenReady == voice.key { chooseWhenReady = nil }
        if playWhenReady == voice.key { playWhenReady = nil }
        store.cancel(voice)
    }

    private func remove(_ voice: NeuralVoice) {
        if preview.playing == voice.id { preview.stop() }
        if selection == voice.id { selection = nil }
        store.remove(voice)
    }

    private func installedChanged() {
        if let key = chooseWhenReady, store.installed[key] != nil, let voice = store.catalog.voice(withKey: key) {
            selection = voice.id
            chooseWhenReady = nil
        }
        if let key = playWhenReady, store.installed[key] != nil, let voice = store.catalog.voice(withKey: key) {
            playWhenReady = nil
            preview.toggle(voice, rate: rate)
        }
    }

    /// A download that ended without a voice (it failed, or was cancelled) stops being waited for.
    private func transfersChanged() {
        for key in [chooseWhenReady, playWhenReady].compactMap({ $0 }) where store.progress[key] == nil && store.installed[key] == nil {
            if chooseWhenReady == key { chooseWhenReady = nil }
            if playWhenReady == key { playWhenReady = nil }
        }
    }

    // MARK: Shared

    private var chosenMark: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ptAccent)
            .accessibilityHidden(true)
    }

    private func sampleButton(_ voice: SpeechVoice?) -> some View {
        let playing = preview.playing == (voice?.id ?? "")
        return Button { preview.toggle(voice, rate: rate) } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(Color.ptAccent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(playing ? "Stop sample" : "Hear \(voice?.displayName ?? "the automatic voice")")
    }

    private func load() async {
        // right after launch iOS can answer with an empty list for a moment
        for _ in 0..<5 {
            voices = SystemVoices.readable()
            if !voices.isEmpty { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        looked = true
    }

    private static func languageName(_ code: String) -> String {
        (Locale.current.localizedString(forLanguageCode: code) ?? code).localizedCapitalized
    }

    private static func regionName(_ code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code)
    }
}

private struct QualityBadge: View {
    let text: String
    let premium: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(premium ? Color.ptAccent : Color.secondary)
            .background((premium ? Color.ptAccent : Color.secondary).opacity(0.15), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// Speed, voice and a sample — the same rows in Settings and in the reader's Reading sheet.
/// Put inside a `Form` (or `List`) that sits in a `NavigationStack`.
struct ReadAloudControls: View {
    @Binding var rate: Double
    /// The chosen voice's identifier; nil is Automatic.
    @Binding var voice: String?

    @ObservedObject private var preview = SpeechPreview.shared
    @State private var installed: [SpeechVoice] = []
    private let store = NeuralVoiceStore.shared

    private var neural: Bool { voice.flatMap(NeuralVoice.key(fromID:)) != nil }

    var body: some View {
        Stepper(value: $rate, in: SpeechRateMap.range(neural: neural), step: SpeechRateMap.step) {
            LabeledContent("Speed", value: SpeechRateMap.label(rate))
        }
        NavigationLink {
            VoiceListView(selection: $voice, rate: rate)
        } label: {
            LabeledContent("Voice", value: voiceName)
        }
        Button { hear() } label: {
            Label(
                preview.playing == nil ? "Hear This Voice" : "Stop",
                systemImage: preview.playing == nil ? "play.fill" : "stop.fill")
        }
        .onAppear { installed = SystemVoices.installed() }
        .onDisappear { preview.stop() }
        // a speed a device voice can't reach, after switching to one
        .onChange(of: voice) { _, _ in
            let range = SpeechRateMap.range(neural: neural)
            rate = min(max(rate, range.lowerBound), range.upperBound)
        }
    }

    private func hear() {
        if let id = voice, let chosen = store.catalog.voice(withID: id), store.isInstalled(chosen) {
            preview.toggle(chosen, rate: rate)
        } else {
            preview.toggle(voice.flatMap { id in installed.first { $0.id == id } }, rate: rate)
        }
    }

    /// A voice that has since been removed from the phone reads as Automatic.
    private var voiceName: String {
        if let id = voice, let chosen = store.catalog.voice(withID: id), store.isInstalled(chosen) {
            return "\(chosen.displayName) (Neural)"
        }
        return voice.flatMap { id in installed.first { $0.id == id } }?.displayName ?? "Automatic"
    }
}
