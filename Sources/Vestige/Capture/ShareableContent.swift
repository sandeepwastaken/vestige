import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Fetches shareable content without letting ScreenCaptureKit's non-`Sendable`
/// classes escape.
///
/// Every function here is `nonisolated`, so `SCShareableContent` and the objects
/// hanging off it are created and consumed inside the same non-isolated context
/// and never cross an actor boundary — which the compiler would otherwise
/// reject, correctly.
enum ShareableContentProvider {
    /// Confirms the capture server will actually talk to this process.
    ///
    /// This is the real permission test: `CGPreflightScreenCaptureAccess` can
    /// report success while the capture server still refuses, which happens
    /// when access was granted after launch.
    static func verifyAccess() async throws {
        _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    /// Builds the content filter for a capture target.
    ///
    /// Returns the filter with the source's true pixel size, read from the
    /// filter rather than computed: `SCContentFilter` reports `contentRect` in
    /// points and `pointPixelScale` separately, which is the only way to get a
    /// mixed Retina/non-Retina setup right — a window on an external 1x display
    /// has a different scale from the same window on the built-in panel.
    ///
    /// An unresolvable window target falls back to display capture: an
    /// unexpected full-screen clip beats a buffer that silently holds nothing.
    static func makeFilter(for target: CaptureTarget) async throws -> (filter: SCContentFilter, pixelSize: CGSize) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        if case .applicationWindow(let pid, let name) = target {
            if let window = primaryWindow(ofProcess: pid, in: content) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                return (filter, pixelSize(of: filter))
            }
            Log.capture.notice("No capturable window for \(name, privacy: .public); capturing the display instead")
        }

        let displayID: CGDirectDisplayID? = if case .display(let id) = target { id } else { nil }
        let display = try resolveDisplay(withID: displayID, in: content)

        // Vestige's own windows are excluded so the menu bar panel and settings
        // sheet never appear in a clip.
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows(in: content))
        return (filter, pixelSize(of: filter))
    }

    /// The window most likely to *be* the game.
    ///
    /// Games commonly open several windows — a splash screen, a hidden helper,
    /// an anti-cheat overlay — so the largest on-screen one is chosen rather
    /// than the first. Tiny windows are rejected outright because a 1×1 helper
    /// window would otherwise win when the real window has not yet appeared.
    private static func primaryWindow(ofProcess pid: pid_t, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { window in
                window.owningApplication?.processID == pid
                    && window.isOnScreen
                    && window.frame.width >= 200
                    && window.frame.height >= 200
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func resolveDisplay(
        withID id: CGDirectDisplayID?,
        in content: SCShareableContent
    ) throws -> SCDisplay {
        guard let first = content.displays.first else {
            throw CaptureError.noDisplaysAvailable
        }
        if let id, let match = content.displays.first(where: { $0.displayID == id }) {
            return match
        }
        return content.displays.first { $0.displayID == CGMainDisplayID() } ?? first
    }

    private static func pixelSize(of filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        return CGSize(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale
        )
    }

    /// Vestige's own windows, so the capture never includes the menu bar popover
    /// or settings window — recording your own UI while clipping looks broken.
    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }
}

enum CaptureError: LocalizedError, Sendable {
    case noDisplaysAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplaysAvailable:
            "No displays are available to capture."
        }
    }
}
