import SwiftUI

struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings
    /// False for PDFs and comics, whose pages are fixed: font, spacing and margins are hidden.
    var adjustsType = true

    var body: some View {
        Form {
            Section("Theme") {
                ThemePicker(theme: $settings.theme)
                Toggle("Night theme after dark", isOn: $settings.autoNight)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dim").font(.subheadline)
                    Slider(value: $settings.dim, in: 0 ... 0.6)
                        .accessibilityLabel("Dim the page")
                        .accessibilityValue("\(Int(settings.dim / 0.6 * 100)) percent")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Warmth").font(.subheadline)
                    Slider(value: $settings.warmth, in: 0 ... 1)
                        .accessibilityLabel("Warm the page")
                        .accessibilityValue("\(Int(settings.warmth * 100)) percent")
                }
                Toggle("Reading ruler", isOn: $settings.ruler)
            } header: {
                Text("Light")
            } footer: {
                Text("Dimming and warmth are for this app only; the ruler shades everything but a few lines, and its handle moves it.")
            }

            if adjustsType {
            Section("Type") {
                Picker("Font", selection: $settings.font) {
                    ForEach(ReaderSettings.FontChoice.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size")
                        .font(.subheadline)
                    Slider(value: $settings.fontSize, in: 0.7 ... 2, step: 0.1)
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(Int(settings.fontSize * 100)) percent")
                }
                Picker("Line spacing", selection: $settings.spacing) {
                    ForEach(ReaderSettings.Spacing.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                Toggle("Justify text", isOn: $settings.justify)
                Toggle("Bold the start of each word", isOn: $settings.bionic)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Letter spacing").font(.subheadline)
                    Slider(value: $settings.letterSpacing, in: 0 ... 0.3, step: 0.025)
                        .accessibilityLabel("Letter spacing")
                        .accessibilityValue(settings.letterSpacing == 0 ? "the book's own" : "\(Int(settings.letterSpacing * 100)) percent")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word spacing").font(.subheadline)
                    Slider(value: $settings.wordSpacing, in: 0 ... 0.5, step: 0.05)
                        .accessibilityLabel("Word spacing")
                        .accessibilityValue(settings.wordSpacing == 0 ? "the book's own" : "\(Int(settings.wordSpacing * 100)) percent")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paragraph spacing").font(.subheadline)
                    Slider(value: $settings.paragraphSpacing, in: 0 ... 2, step: 0.25)
                        .accessibilityLabel("Paragraph spacing")
                        .accessibilityValue(settings.paragraphSpacing == 0 ? "the book's own" : String(format: "%.2g", settings.paragraphSpacing))
                }
            }
            }

            Section("Layout") {
                if adjustsType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Margins")
                            .font(.subheadline)
                        Slider(value: $settings.margins, in: 0.5 ... 2, step: 0.25)
                            .accessibilityLabel("Page margins")
                            .accessibilityValue("\(Int(settings.margins * 100)) percent")
                    }
                }
                Toggle("Scroll instead of pages", isOn: $settings.scroll)
                if !settings.scroll, adjustsType {
                    Picker("Page layout", selection: $settings.columns) {
                        ForEach(ReaderSettings.Columns.allCases) {
                            Text($0.label).tag($0)
                        }
                    }
                    Picker("Page turn", selection: $settings.pageTurn) {
                        ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
                Picker("Tap to turn", selection: $settings.tapZone) {
                    ForEach(ReaderSettings.TapZone.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Tap in the fingers on a turn", isOn: $settings.turnHaptic)
                Toggle("Rustle of the page on a turn", isOn: $settings.turnSound)
                Toggle("Keep the screen on", isOn: $settings.keepAwake)
            }

            Section {
                ReadAloudControls(rate: $settings.speechRate, voice: $settings.voiceIdentifier)
                Toggle("Dim the screen while it reads", isOn: $settings.dimWhileNarrating)
            } header: {
                Text("Read aloud")
            } footer: {
                Text("The screen dims a few seconds after the controls are put away. A tap brings it back; the voice carries on.")
            }

            Section {
                ReadAloudHighlightRows(highlights: $settings.highlights)
            } header: {
                Text("Highlight as it reads")
            } footer: {
                Text(ReadAloudHighlightRows.footnote)
            }
        }
    }
}

/// The five page palettes as little "Aa" tiles, in the colours they will have.
private struct ThemePicker: View {
    @Binding var theme: ReaderSettings.ThemeChoice

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ReaderSettings.ThemeChoice.allCases) { choice in
                let selected = theme == choice
                Button { theme = choice } label: {
                    VStack(spacing: 6) {
                        Text("Aa")
                            .font(.system(.title3, design: .serif).weight(.semibold))
                            .foregroundStyle(Color(rgb: choice.text))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color(rgb: choice.background), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.ptAccent : Color.secondary.opacity(0.35),
                                        lineWidth: selected ? 3 : 1))
                        Text(choice.label)
                            .font(.caption2)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
