import AppKit
// UNNotificationSettings and friends predate strict concurrency and are not
// marked Sendable, though they are immutable value-like snapshots.
@preconcurrency import UserNotifications

/// Posts a notification when a clip is saved, with actions to open or reveal it.
///
/// Notifications are the app's only feedback that the hotkey worked, since
/// Vestige has no window open while gaming. If the user denies notification
/// permission the app degrades to a sound only — the clip is still saved, and
/// nothing blocks on this.
@MainActor
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isAuthorized = false

    /// Invoked when the user activates a notification or one of its buttons.
    var onReveal: ((URL) -> Void)?
    var onOpen: ((URL) -> Void)?

    private let center = UNUserNotificationCenter.current()

    private enum Identifier {
        static let category = "app.vestige.clip-saved"
        static let reveal = "reveal"
        static let open = "open"
        static let clipPath = "clipPath"
    }

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let reveal = UNNotificationAction(
            identifier: Identifier.reveal,
            title: "Show in Finder",
            options: []
        )
        let open = UNNotificationAction(
            identifier: Identifier.open,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Identifier.category,
            actions: [open, reveal],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Authorization

    /// Requests permission. Safe to call repeatedly; after the first answer
    /// macOS returns the stored decision without prompting again.
    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.app.notice("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            isAuthorized = false
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    // MARK: - Posting

    func clipSaved(_ clip: Clip, showsAlert: Bool, playsSound: Bool) async {
        // A sound is played directly when alerts are off or unavailable, so the
        // hotkey always produces *some* confirmation.
        guard showsAlert, isAuthorized else {
            if playsSound { NSSound(named: "Glass")?.play() }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Replay saved"
        content.body = "\(Formatters.duration(clip.duration)) · \(Formatters.fileSize.string(fromByteCount: clip.fileSize))"
        content.categoryIdentifier = Identifier.category
        content.userInfo = [Identifier.clipPath: clip.url.path(percentEncoded: false)]
        if playsSound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: clip.url.path(percentEncoded: false),
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            Log.app.notice("Could not post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    func failure(_ message: String) async {
        guard isAuthorized else {
            NSSound(named: "Funk")?.play()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Couldn't save replay"
        content.body = message

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shows the banner even though Vestige is the frontmost process from
    /// macOS's point of view when the hotkey fires.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let path = userInfo[Identifier.clipPath] as? String else { return }
        let url = URL(fileURLWithPath: path)
        let action = response.actionIdentifier

        await MainActor.run {
            switch action {
            case Identifier.open, UNNotificationDefaultActionIdentifier:
                self.onOpen?(url)
            case Identifier.reveal:
                self.onReveal?(url)
            default:
                break
            }
        }
    }
}
