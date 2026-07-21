import Observation
import ServiceManagement

/// Wraps `SMAppService` login-item registration.
///
/// Unlike a preference, this reflects state macOS owns: the user can disable
/// Vestige from System Settings › General › Login Items at any time, so the
/// value is always read back from the system rather than cached in
/// `UserDefaults`, where it could silently drift out of sync.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false

    /// Set when registration fails — most often because the app is being run
    /// from a location macOS will not register, such as a mounted disk image.
    private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = service.status == .requiresApproval
                ? "Approve Vestige in System Settings › General › Login Items."
                : "Couldn't update the login item. Try moving Vestige to your Applications folder."
        }

        refresh()
    }
}
