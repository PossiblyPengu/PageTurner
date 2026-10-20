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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.displayName)
                            Text("\(voice.quality.label) · \(voice.langName) · \(voice.country) · \(voice.sizeLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

    private func remove(_ voice: NeuralVoice) {
        if selection == voice.id { selection = nil }
        store.remove(voice)
    }
}
