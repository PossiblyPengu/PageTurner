import SwiftUI

extension String {
    /// An alert title from a notice sentence: the lead before the first colon,
    /// em-dash or line break ("Couldn't play x.m4b: …" → "Couldn't play x.m4b").
    /// A notice with no lead to cut falls back, so it isn't read twice.
    func ptAlertTitle(or fallback: String) -> String {
        for marker in [": ", " — ", "\n"] {
            if let cut = range(of: marker)?.lowerBound, cut > startIndex {
                return String(self[..<cut])
            }
        }
        return fallback
    }
}

/// The settings button every tab carries, always the last button on the trailing side of the top bar — one definition,
/// so it cannot drift from tab to tab.
struct SettingsToolbarItem: ToolbarContent {
    let router: AppRouter

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { router.showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
    }
}
