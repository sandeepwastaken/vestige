import AppKit
import Foundation

/// A game the user explicitly told Vestige to watch for.
///
/// The name is stored alongside the bundle identifier rather than resolved on
/// demand, so the list still reads sensibly when a game is uninstalled or the
/// external drive it lives on is unplugged — the user sees "Baldur's Gate 3"
/// and can remove it, instead of an opaque reverse-DNS string.
struct SelectedGame: Codable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    var name: String

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    init?(applicationURL: URL) {
        guard let bundle = Bundle(url: applicationURL),
              let identifier = bundle.bundleIdentifier
        else { return nil }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent

        self.init(bundleIdentifier: identifier, name: displayName)
    }

    init?(runningApplication: NSRunningApplication) {
        guard let identifier = runningApplication.bundleIdentifier else { return nil }
        self.init(
            bundleIdentifier: identifier,
            name: runningApplication.localizedName ?? identifier
        )
    }

    /// The app's own icon, for the settings list. Nil once the app is gone.
    @MainActor
    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    /// Whether this app is still installed, so the UI can mark stale entries.
    @MainActor
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
