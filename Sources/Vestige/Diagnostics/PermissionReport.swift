import CoreGraphics
import Foundation

/// Reports Screen Recording status, and proves the polling path cannot prompt.
/// Run with `Vestige --permissions`.
///
/// Exists because of a real bug: an earlier version polled `SCShareableContent`
/// every two seconds, which raises the system dialog whenever TCC holds no
/// decision — an endless stream of prompts the user could not dismiss. The
/// guard against that is easy to delete while "simplifying", so being able to
/// demonstrate it rather than assert it is worth a diagnostic.
///
/// Calls `PermissionsManager.probe()`, the same function the app's timer uses,
/// so this cannot pass while the real path regresses.
enum PermissionReport {
    static func runAndExit() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var authorized = false

        Task {
            authorized = await run()
            semaphore.signal()
        }
        semaphore.wait()

        exit(authorized ? 0 : 1)
    }

    private static func run() async -> Bool {
        print("Vestige permission report\n")

        print("Bundle identifier : \(Bundle.main.bundleIdentifier ?? "(not bundled)")")
        print("Bundle path       : \(Bundle.main.bundleURL.path(percentEncoded: false))")
        print("Recorded grant    : \(CGPreflightScreenCaptureAccess() ? "yes" : "no")")

        // Each pass is exactly what the app's 2-second timer does. If any of
        // them could prompt, this would block on a dialog instead of finishing.
        print("\nRunning the automatic check 5 times (this must stay silent):")

        var probe = PermissionsManager.Probe(hasRecordedGrant: false, captureWorks: false)
        for attempt in 1...5 {
            probe = await PermissionsManager.probe()
            print("  \(attempt). grant=\(probe.hasRecordedGrant) capture=\(probe.captureWorks)")
        }

        print("")
        switch (probe.hasRecordedGrant, probe.captureWorks) {
        case (true, true):
            print("Screen Recording is granted and working.")
        case (true, false):
            print("""
            Screen Recording is granted, but this process started before the
            grant and macOS does not extend it retroactively.

            Quit and reopen Vestige.
            """)
        default:
            print("""
            Screen Recording is not granted for this build.

            If System Settings already lists Vestige as switched on, that entry
            belongs to a different build. macOS ties the grant to a build's code
            signature, so to it a rebuilt app is a different app wearing the same
            name.

            Fix: System Settings > Privacy & Security > Screen & System Audio
            Recording, select Vestige, click the - button to remove it, then
            reopen Vestige and grant access once.
            """)
        }

        print("\nNo permission dialog should have appeared while this ran.")
        return probe.hasRecordedGrant && probe.captureWorks
    }
}
