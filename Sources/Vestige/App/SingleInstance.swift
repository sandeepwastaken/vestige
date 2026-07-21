import AppKit
import Foundation

/// Ensures at most one Vestige process runs at a time.
///
/// Two live instances are worse than a crash: both hold their own `SCStream`,
/// both register the same global hotkey, and both write a clip to the same
/// path when it fires. Whichever finishes last wins — even the one that failed
/// to encode audio and fell back to video-only, which is how a good clip got
/// silently overwritten with a silent one.
enum SingleInstance {
    /// Marks a launch that is deliberately replacing every other instance,
    /// rather than an accidental second launch that should defer to the one
    /// already running. Passed by `PermissionsManager.relaunch()`.
    static let relaunchArgument = "--relaunched"

    /// Call once at process start, before any capture or UI setup begins.
    static func enforce() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        guard !others.isEmpty else { return }

        guard CommandLine.arguments.contains(relaunchArgument) else {
            // An ordinary second launch: the existing instance already owns
            // capture and the hotkey, so this one has nothing useful to do.
            exit(0)
        }

        // Terminating from here — the instance that has just confirmed it
        // launched — beats asking the old one to quit itself once the new one
        // appeared to start. That completion handler could fail silently and
        // leave both running indefinitely, which is what happened.
        for other in others { other.terminate() }

        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
