import SwiftUI

/// The settings window.
///
/// Three tabs, each holding one coherent group. Everything applies immediately —
/// there is no Save button and no Apply, matching how macOS system settings
/// behave.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "video") }

            GamesSettingsView()
                .tabItem { Label("Games", systemImage: "gamecontroller") }

            SharingSettingsView()
                .tabItem { Label("Sharing", systemImage: "square.and.arrow.up") }

            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

/// A labelled row used throughout settings, with optional explanatory text.
///
/// Keeping this in one place is what makes the three tabs look like one app
/// rather than three screens that happen to sit next to each other.
struct SettingsRow<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) { content }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
