import AppKit
import Observation

/// A game Vestige believes is currently running.
struct DetectedGame: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?

    /// Needed to locate the game's window for window-only capture.
    let processIdentifier: pid_t

    /// True when the user nominated this app themselves rather than Vestige
    /// guessing. Surfaced in the UI so a wrong guess is obviously a guess.
    var wasChosenByUser: Bool = false
}

/// Detects running games so the buffer can start and stop on its own.
///
/// macOS exposes no "is this a game" API, so this combines four signals in
/// descending order of trust:
///
/// 0. **The user's own list**, which overrides every heuristic below including
///    the launcher exclusion — someone who adds Steam deliberately meant it.
/// 1. `LSApplicationCategoryType` declaring a games category.
/// 2. The executable living in a known games directory (`steamapps`, Epic),
///    which catches the long tail that declares no category.
/// 3. A curated list of publisher bundle-ID prefixes.
///
/// Launchers are excluded from the automatic signals: having Steam open is not
/// playing a game.
@MainActor
@Observable
final class GameDetector {
    private(set) var currentGame: DetectedGame?

    /// Apps the user nominated. Assigning re-evaluates immediately, so adding a
    /// game that is already running starts the buffer without waiting for a poll.
    var selectedBundleIDs: Set<String> = [] {
        didSet {
            guard selectedBundleIDs != oldValue, isRunning else { return }
            evaluate()
        }
    }

    var isGameRunning: Bool { currentGame != nil }

    /// Called when detection flips between "a game is running" and "none is".
    var onChange: ((DetectedGame?) -> Void)?

    private let observers = NotificationObservers(center: NSWorkspace.shared.notificationCenter)
    private var pollTask: Task<Void, Never>?
    private var isRunning = false
    private var hasInstalledObservers = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Registered once for the object's lifetime, not once per start.
        // `stop()` cannot unregister them — switching the buffer policy to
        // manual and back would otherwise add a second and third copy of every
        // observer, running detection several times per app switch. `evaluate()`
        // is gated on `isRunning` instead.
        if !hasInstalledObservers {
            hasInstalledObservers = true
            for name: Notification.Name in [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didActivateApplicationNotification
            ] {
                observers.observe(name) { [weak self] in self?.evaluate() }
            }
        }

        // Workspace notifications cover nearly everything, but a game that
        // relaunches itself into a different process (common with launchers and
        // anti-cheat shims) can slip through. A slow poll is the safety net.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.evaluate()
            }
        }

        evaluate()
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        currentGame = nil
    }

    // MARK: - Detection

    private func evaluate() {
        // Workspace notifications outlive `stop()`, so without this a stopped
        // detector would keep repopulating `currentGame` on the next app switch.
        guard isRunning else { return }

        let applications = NSWorkspace.shared.runningApplications
        let selected = selectedBundleIDs

        // Prefer the frontmost app: if the user has alt-tabbed out of a game to
        // a browser, the game is still the thing worth clipping, but if two
        // games are running the active one is the right answer.
        let frontmost = applications.first { $0.isActive }
        var detected: DetectedGame?

        if let frontmost, let game = Self.game(from: frontmost, selected: selected) {
            detected = game
        } else {
            // User-chosen apps win over anything merely detected, even when the
            // detected one happens to come first in the process list.
            //
            // Materialised once: chaining two lazy passes here ran the bundle
            // checks twice over every running application on each evaluation.
            let games = applications.compactMap { Self.game(from: $0, selected: selected) }
            detected = games.first { $0.wasChosenByUser } ?? games.first
        }

        guard detected != currentGame else { return }
        currentGame = detected

        if let detected {
            Log.games.info("Detected game: \(detected.name, privacy: .public)")
        } else {
            Log.games.info("No game running")
        }
        onChange?(detected)
    }

    private nonisolated static func game(
        from application: NSRunningApplication,
        selected: Set<String>
    ) -> DetectedGame? {
        guard application.activationPolicy == .regular,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleURL = application.bundleURL
        else { return nil }

        let name = application.localizedName
            ?? bundleURL.deletingPathExtension().lastPathComponent

        // Signal 0: the user said so. Checked before the launcher exclusion,
        // because someone who deliberately adds a launcher wants it watched.
        if let identifier = application.bundleIdentifier, selected.contains(identifier) {
            return DetectedGame(
                name: name,
                bundleIdentifier: identifier,
                processIdentifier: application.processIdentifier,
                wasChosenByUser: true
            )
        }

        let bundleID = application.bundleIdentifier?.lowercased()

        if let bundleID, launcherBundleIdentifiers.contains(where: bundleID.hasPrefix) {
            return nil
        }

        guard isGame(bundleURL: bundleURL, bundleIdentifier: bundleID) else { return nil }

        return DetectedGame(
            name: name,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    private nonisolated static func isGame(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        // Signal 1: the app declares itself a game.
        if let category = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category.lowercased().contains("games") {
            return true
        }

        // Signal 2: it lives where games get installed.
        let path = bundleURL.path(percentEncoded: false).lowercased()
        if gameInstallPathFragments.contains(where: path.contains) {
            return true
        }

        // Signal 3: a known publisher.
        if let bundleIdentifier,
           knownGameBundlePrefixes.contains(where: bundleIdentifier.hasPrefix) {
            return true
        }

        return false
    }

    /// Storefronts and launchers. Running one is not playing a game.
    private nonisolated static let launcherBundleIdentifiers: Set<String> = [
        "com.valvesoftware.steam",
        "com.epicgames.launcher",
        "com.blizzard.battle.net",
        "com.gog.galaxy",
        "com.ea.eadesktop",
        "com.ubisoft.connect",
        "org.prismlauncher",
        "com.mojang.minecraftlauncher"
    ]

    private nonisolated static let gameInstallPathFragments: [String] = [
        "/steamapps/",
        "/epic games/",
        "/gog games/",
        "/crossover/",
        "/whisky/",
        "/applications/games/"
    ]

    private nonisolated static let knownGameBundlePrefixes: [String] = [
        "com.valvesoftware.",
        "com.riotgames.",
        "com.blizzard.",
        "com.mojang.",
        "com.rockstargames.",
        "com.ea.",
        "com.ubisoft.",
        "com.aspyr.",
        "com.feralinteractive.",
        "com.larian.",
        "com.innersloth.",
        "com.re-logic.",
        "com.paradoxplaza.",
        "com.bethesda.",
        "com.2k.",
        "com.square-enix.",
        "com.hoyoverse.",
        "com.mihoyo.",
        "unity.",
        "com.unity."
    ]
}
