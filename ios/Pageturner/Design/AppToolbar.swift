import SwiftUI

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
