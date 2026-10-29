import SwiftUI

extension NeuralVoiceSummary {
    @MainActor
    static func text(for store: NeuralVoiceStore) -> String {
        text(count: store.installed.count, bytes: store.usedBytes)
    }
}

/// The neural voices that are on this iPhone, what they take, and a way to delete them.
struct SavedVoicesView: View {
    /// The chosen voice, so deleting it can fall back to Automatic.
    @Binding var selection: String?
    private let store = NeuralVoiceStore.shared

    var body: some View {
        Group {
            if store.installedVoices.isEmpty {
                ContentUnavailableView(
                    "No Saved Voices", systemImage: "arrow.down.circle",
                    description: Text("Neural voices you download are kept here, so they work offline."))
            } else {
                List {
                Section {
                    ForEach(store.installedVoices) { voice in
                        savedRow(voice)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { remove(voice) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAction(named: "Delete") { remove(voice) }
                    }
                } footer: {
                    Text("\(NeuralVoiceSummary.text(for: store)) in all. Deleting a voice frees its space; you can download it again whenever you like. Swipe a voice to delete it.")
                }
                }
            }
        }
        .ptSoftScrollEdges()
        .navigationTitle("Saved Voices")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.ptAccent)
    }

    @ViewBuilder
    private func savedRow(_ voice: NeuralVoice) -> some View {
        let line = VStack(alignment: .leading, spacing: 2) {
            Text(voice.displayName)
            Text([voice.quality.label, voice.langName, voice.country, voice.sizeLabel,
                  voice.speakers > 1 ? "\(voice.speakers) speakers" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if voice.speakers > 1 {
            NavigationLink {
                SpeakerPickerView(voice: voice, selection: $selection, rate: 1)
            } label: { line }
        } else {
            line
        }
    }

    private func remove(_ voice: NeuralVoice) {
        if selection.flatMap(NeuralVoice.key(fromID:)) == voice.key { selection = nil }
        store.remove(voice)
    }
}

/// One speaker of a multi-speaker neural voice ("p225", "edwards" — or just "Speaker 12"):
/// choose it, or hear it. Presented as a sheet from the voice list (wrapped in a
/// NavigationStack there) and pushed from Saved Voices — `dismiss` covers both.
struct SpeakerPickerView: View {
    let voice: NeuralVoice
    /// The chosen voice identifier; a pick sets `voice.id(withSpeaker: sid)`.
    @Binding var selection: String?
    /// How fast the samples are spoken.
    let rate: Double

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @ObservedObject private var preview = SpeechPreview.shared
    private let store = NeuralVoiceStore.shared

    private var info: NeuralVoiceFormat.Installed? { store.installed[voice.key] }

    var body: some View {
        List {
            ForEach(0 ..< max(voice.speakers, 1), id: \.self) { sid in
                if shown(sid) { row(sid) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search speakers")
        .navigationTitle(voice.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { preview.stop() }
        .tint(.ptAccent)
    }

    private func name(for sid: Int) -> String { info?.speakerName(sid) ?? "Speaker \(sid + 1)" }

    private func shown(_ sid: Int) -> Bool {
        query.isEmpty || name(for: sid).localizedCaseInsensitiveContains(query)
    }

    private func row(_ sid: Int) -> some View {
        let id = voice.id(withSpeaker: sid)
        return HStack(spacing: 8) {
            Button {
                selection = id
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text(name(for: sid)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if selection == id {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.ptAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selection == id ? .isSelected : [])
            Button { preview.toggle(voice, rate: rate, sid: sid) } label: {
                Image(systemName: preview.playing == id ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(Color.ptAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(preview.playing == id ? "Stop sample" : "Hear \(name(for: sid))")
        }
    }
}
