import SwiftUI

/// Settings → Read Aloud: the speed, voice and highlighting used whenever a book is read aloud.
/// (The reader's Reading sheet edits the same values.)
struct ReadAloudSection: View {
    @State private var rate: Double
    @State private var voice: String?
    @State private var highlights: ReadAloudHighlights
    @AppStorage("speech-skip-page-numbers") private var skipPageNumbers = true
    private let store = NeuralVoiceStore.shared
    @ObservedObject private var pronunciations = PronunciationStore.shared

    init() {
        let settings = ReaderSettings.load()
        _rate = State(initialValue: settings.speechRate)
        _voice = State(initialValue: settings.voiceIdentifier)
        _highlights = State(initialValue: settings.highlights)
    }

    var body: some View {
        Section {
            ReadAloudControls(rate: $rate, voice: $voice)
            NavigationLink {
                SavedVoicesView(selection: $voice)
            } label: {
                LabeledContent("Saved Voices", value: NeuralVoiceSummary.text(for: store))
            }
            NavigationLink {
                PronunciationListView(voiceID: voice, rate: rate)
            } label: {
                LabeledContent("Pronunciations", value: pronunciations.entries.isEmpty ? "None" : "\(pronunciations.entries.count)")
            }
            Toggle("Skip page numbers", isOn: $skipPageNumbers)
        } header: {
            Text("Read Aloud")
        } footer: {
            Text("Choose a voice from this iPhone, or a neural one — it downloads once (20–140 MB, shown on each voice), sounds more natural and keeps reading with the screen locked. Automatic picks the best installed voice for each book’s language; Enhanced and Premium device voices can be added under Settings → Accessibility → Spoken Content → Voices.")
        }
        .onChange(of: rate) { _, _ in save() }
        .onChange(of: voice) { _, _ in save() }

        Section {
            ReadAloudHighlightRows(highlights: $highlights)
        } header: {
            Text("Highlight as it reads")
        } footer: {
            Text(ReadAloudHighlightRows.footnote)
        }
        .onChange(of: highlights) { _, _ in save() }
    }

    /// Only the read-aloud values, written over a fresh copy — the type settings are
    /// the reader's to change.
    private func save() {
        var settings = ReaderSettings.load()
        settings.speechRate = rate
        settings.voiceIdentifier = voice
        settings.highlights = highlights
        settings.save()
    }
}
