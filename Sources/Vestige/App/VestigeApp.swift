import AppKit
import SwiftUI

/// Identifiers for the app's auxiliary windows.
///
/// Explicit `Window` scenes rather than the `Settings` scene, so the menu bar
/// panel can open them with `openWindow(id:)` — consistent across macOS
/// versions, unlike the private selector a `Settings` scene requires.
enum WindowID {
    static let settings = "settings"
    static let clips = "clips"
    static let about = "about"
    static let player = "player"
}

/// The `@main` attribute is deliberately absent: `main.swift` is the entry
/// point so that command-line flags can be handled before any UI is created.
struct VestigeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    /// Startup happens here rather than in a view's `.task`.
    ///
    /// With `.menuBarExtraStyle(.window)` SwiftUI does not build the panel's
    /// content until the icon is first clicked, so anything attached to that
    /// view — the global hotkey, permissions, starting the buffer — would wait
    /// for someone to open the menu, exactly when a replay buffer is useless.
    init() {
        let model = AppModel()
        _model = State(initialValue: model)

        Task { @MainActor in
            await model.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
                .modifier(ClipsWindowOpener(model: model))
        } label: {
            MenuBarLabel(state: model.menuBarState)
        }
        // The window style allows a real layout — buffer status, thumbnails,
        // a prominent save button — rather than a flat list of menu items.
        .menuBarExtraStyle(.window)

        Window("Vestige Settings", id: WindowID.settings) {
            SettingsWindow()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("Clips", id: WindowID.clips) {
            ClipLibraryView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 520)
        .commandsRemoved()

        // One player window per clip, keyed by URL, so several clips can be
        // open side by side while reviewing a session.
        WindowGroup(id: WindowID.player, for: URL.self) { $url in
            if let url {
                ClipPlayerLoader(url: url)
                    .environment(model)
            }
        }
        .defaultSize(width: 900, height: 560)
        .commandsRemoved()

        Window("About Vestige", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

/// Menu bar icon reflecting capture state at a glance.
///
/// Vestige's own glyph rather than an SF Symbol, so the item is recognisable
/// among a row of others. State rides on top as a small badge, except missing
/// permission, which takes over the slot so it reads as a problem.
struct MenuBarLabel: View {
    let state: AppModel.MenuBarState

    var body: some View {
        Group {
            if state == .needsPermission {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if let glyph = Self.glyph {
                Image(nsImage: glyph)
                    .overlay(alignment: .topTrailing) { badge }
            } else {
                // The bundled glyph is missing, which happens when running the
                // raw SwiftPM binary rather than the assembled .app.
                Image(systemName: state.symbolName)
            }
        }
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .buffering:
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
                .offset(x: 2, y: -1)
        case .saving:
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
                .offset(x: 2, y: -1)
        case .idle, .needsPermission:
            EmptyView()
        }
    }

    /// Loaded once. `isTemplate` is what lets macOS recolour the glyph for
    /// light, dark, and highlighted menu bars.
    @MainActor
    private static let glyph: NSImage? = {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        return image
    }()
}

/// Gives the model a way to open the clip library.
///
/// `openWindow` is only available from the SwiftUI environment, but the library
/// also has to be reachable from a global hotkey, which fires outside any view.
/// This hands the model a closure once a view exists to supply it.
private struct ClipsWindowOpener: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.openClipsWindow = { openWindow(id: WindowID.clips) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Vestige lives in the menu bar, so closing the settings or clips window
    /// must never terminate it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already hides the Dock icon; this makes the policy
        // explicit for the case where the app is launched from a debugger or a
        // build that has not been re-bundled.
        NSApp.setActivationPolicy(.accessory)
    }
}
