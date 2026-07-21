import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit

/// Tracks the one permission Vestige cannot work without.
///
/// Accessibility access is deliberately never requested: global hotkeys go
/// through Carbon's `RegisterEventHotKey`, which needs no TCC grant. Screen
/// Recording is the only prompt a user has to answer.
@MainActor
@Observable
final class PermissionsManager {
    enum Status: Equatable, Sendable {
        case unknown
        case authorized
        /// Not granted, or granted after launch without a restart.
        case denied
    }

    private(set) var status: Status = .unknown

    /// Granted in System Settings, but this process still holds a stale denial:
    /// the capture server only serves processes launched after the grant.
    private(set) var requiresRelaunch = false

    /// Set while a manual re-check runs, so the button can show progress.
    private(set) var isChecking = false

    /// Whether the prompt has been raised since launch, so the UI can stop
    /// offering a button macOS will no longer act on.
    private(set) var hasPromptedThisLaunch = false

    private(set) var lastCheckedAt: Date?

    private var pollTask: Task<Void, Never>?

    var isAuthorized: Bool { status == .authorized }

    // MARK: - Checking

    /// Re-evaluates access **without ever raising a system prompt**.
    ///
    /// The order of the two checks is critical. `SCShareableContent` is the
    /// authoritative test, but with no TCC decision recorded it *raises the
    /// permission dialog*, so polling it directly would prompt endlessly.
    /// `CGPreflightScreenCaptureAccess` never prompts and gates it. The gated
    /// query can still fail, and that failure is meaningful: it is exactly the
    /// case where the grant landed after launch and the process needs restarting.
    ///
    /// Anything that may prompt lives in `request()`, reached only from a button.
    @discardableResult
    func refresh() async -> Status {
        let probe = await Self.probe()
        lastCheckedAt = .now

        switch (probe.hasRecordedGrant, probe.captureWorks) {
        case (false, _):
            status = .denied
            requiresRelaunch = false
        case (true, true):
            status = .authorized
            requiresRelaunch = false
        case (true, false):
            status = .denied
            if !requiresRelaunch {
                Log.permissions.notice("Grant exists but the capture server refused; a relaunch is needed")
            }
            requiresRelaunch = true
        }

        // Re-arm the poll if watching became useful again, say because the user
        // removed the grant and hit Check Again.
        if status == .denied, !requiresRelaunch {
            beginMonitoring()
        }

        return status
    }

    struct Probe: Sendable {
        /// TCC holds a positive decision for this exact binary.
        var hasRecordedGrant: Bool
        /// The capture server actually served content to this process.
        var captureWorks: Bool
    }

    /// Performs the permission check, off the main actor.
    ///
    /// `nonisolated` so the `--permissions` diagnostic exercises this exact
    /// code rather than a reimplementation: the guard here is the thing that
    /// must not regress.
    nonisolated static func probe() async -> Probe {
        guard CGPreflightScreenCaptureAccess() else {
            // No grant recorded. Touching ScreenCaptureKit here is what would
            // summon a dialog.
            return Probe(hasRecordedGrant: false, captureWorks: false)
        }

        do {
            try await ShareableContentProvider.verifyAccess()
            return Probe(hasRecordedGrant: true, captureWorks: true)
        } catch {
            return Probe(hasRecordedGrant: true, captureWorks: false)
        }
    }

    /// A user-initiated re-check, surfaced as a button.
    ///
    /// Separate from `refresh()` so the UI can show the check running: it
    /// returns in milliseconds, and without feedback a button that changes
    /// nothing looks broken rather than informative.
    func recheck() async {
        isChecking = true
        defer { isChecking = false }

        async let minimumDelay: Void = Self.sleepBriefly()
        async let check: Void = { _ = await refresh() }()
        _ = await (minimumDelay, check)
    }

    /// The **only** code path in Vestige permitted to raise a system prompt.
    ///
    /// macOS shows the dialog at most once per binary and afterwards silently
    /// returns the stored decision. That is why the UI always offers System
    /// Settings too — past the first answer, this button cannot do anything.
    func request() async {
        hasPromptedThisLaunch = true

        if CGRequestScreenCaptureAccess() {
            await refresh()
        } else {
            status = .denied
            Log.permissions.notice("Screen recording request returned denied")
        }
    }

    /// A floor on the spinner: without it the state flips faster than it can be
    /// perceived and the button appears not to have worked.
    private nonisolated static func sleepBriefly() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    // MARK: - Recovery

    /// Watches for the permission being granted in System Settings while the
    /// app runs, so capture can resume without the user coming back here.
    func beginMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // A nil self retires the loop, which is why no deinit cleanup is
                // needed — Swift 6 forbids reading main-actor state there anyway.
                guard let self else { return }

                // Both terminal states retire rather than idle, so the process
                // is not woken every two seconds for the rest of the session.
                // Authorized cannot regress without a relaunch, and a stale
                // grant needs a relaunch rather than another check.
                if self.status == .authorized || self.requiresRelaunch {
                    self.pollTask = nil
                    return
                }

                await self.refresh()
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches Vestige so a freshly granted permission takes effect.
    ///
    /// The new process terminates this one once it has confirmed it is running
    /// — see `SingleInstance.enforce()`. Doing it the other way round relied on
    /// a completion handler that is not guaranteed to run, and when it silently
    /// did not, two instances captured side by side on the same hotkey.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [SingleInstance.relaunchArgument]

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.permissions.error("Relaunch failed: \(error.localizedDescription)")
            }
        }
    }
}
