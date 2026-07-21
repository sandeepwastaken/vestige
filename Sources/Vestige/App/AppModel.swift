import AppKit
import Observation

/// The application's root view model: owns every component and encodes the
/// policy connecting them.
///
/// Components stay deliberately ignorant of each other — the capture engine
/// knows nothing about games or notifications, the clip store nothing about
/// capture. All coordination lives here, which keeps them independently
/// testable and the app's behaviour readable in one file.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let permissions: PermissionsManager
    let capture: CaptureEngine
    let clips: ClipStore
    let hotkeys: HotkeyManager
    let notifications: NotificationManager
    let games: GameDetector
    let launchAtLogin: LaunchAtLogin
    let metadata: ClipMetadataStore
    let resources = ResourceMonitor()

    private let clipWriter = ClipWriter()
    private let compressor = ClipCompressor()

    /// Set while the user has paused capture by hand. Distinct from "not
    /// running": a paused buffer stays paused even when a game launches.
    private(set) var isPaused = false

    // MARK: - Presentation state

    private(set) var isSavingClip = false

    /// Transient status shown in the menu bar panel after a save attempt.
    private(set) var lastMessage: StatusMessage?

    /// Live buffer occupancy. Only refreshed while the panel is on screen.
    private(set) var bufferStatistics = ReplayBuffer.Statistics()

    /// Whether the user has armed the buffer by hand, for `BufferPolicy.manual`.
    private(set) var isManuallyArmed = false

    struct StatusMessage: Equatable, Sendable {
        enum Kind: Sendable { case success, failure }
        var kind: Kind
        var text: String
    }

    private var statisticsTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?

    // MARK: - Init

    init(
        settings: SettingsStore = SettingsStore(),
        permissions: PermissionsManager = PermissionsManager(),
        capture: CaptureEngine = CaptureEngine(),
        hotkeys: HotkeyManager = HotkeyManager(),
        notifications: NotificationManager = NotificationManager(),
        games: GameDetector = GameDetector(),
        launchAtLogin: LaunchAtLogin = LaunchAtLogin()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.capture = capture
        self.hotkeys = hotkeys
        self.notifications = notifications
        self.games = games
        self.launchAtLogin = launchAtLogin

        let metadata = ClipMetadataStore()
        self.metadata = metadata

        let clips = ClipStore(directory: settings.outputDirectory)
        clips.metadata = metadata
        self.clips = clips
    }

    // MARK: - Startup

    private var hasStarted = false

    /// Brings the app to a working state. Idempotent, so it is safe to call
    /// from more than one lifecycle hook.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        hotkeys.onAction = { [weak self] action in
            Task { await self?.perform(action) }
        }
        hotkeys.apply(settings.hotkeys)

        notifications.onReveal = { [weak self] url in
            self?.revealClip(at: url)
        }
        notifications.onOpen = { url in
            NSWorkspace.shared.open(url)
        }

        games.onChange = { [weak self] _ in
            Task { await self?.evaluateBufferPolicy() }
        }

        games.selectedBundleIDs = Set(settings.selectedGames.map(\.bundleIdentifier))

        clips.beginWatching()
        await clips.refresh()
        metadata.prune(keeping: clips.clips.map(\.url))
        await applyRetentionPolicy()

        await notifications.refreshAuthorization()
        if settings.showsNotifications && !notifications.isAuthorized {
            await notifications.requestAuthorization()
        }

        await permissions.refresh()
        permissions.beginMonitoring()

        observeSettingsChanges()
        observePermissionChanges()

        if settings.bufferPolicy != .manual {
            games.start()
        }
        await evaluateBufferPolicy()
    }

    // MARK: - Reacting to change

    /// Re-applies settings whenever any of them change.
    ///
    /// `withObservationTracking` fires once per change and must be re-armed, so
    /// the continuation re-registers itself. This is the supported way to
    /// observe an `@Observable` outside SwiftUI, and it means no control has to
    /// remember to call back into the model.
    private func observeSettingsChanges() {
        withObservationTracking {
            _ = settings.captureSnapshot
            _ = settings.hotkeys
            _ = settings.outputDirectory
            _ = settings.bufferPolicy
            _ = settings.selectedGames
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applySettings()
                self.observeSettingsChanges()
            }
        }
    }

    private func observePermissionChanges() {
        withObservationTracking {
            _ = permissions.status
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.evaluateBufferPolicy()
                self.observePermissionChanges()
            }
        }
    }

    /// Runs a keyboard action.
    func perform(_ action: HotkeyAction) async {
        switch action {
        case .saveReplay:
            await saveReplay()
        case .saveLast15, .saveLast30:
            await saveReplay(seconds: action.saveDuration)
        case .pauseResume:
            await togglePause()
        case .openClips:
            NSApp.activate(ignoringOtherApps: true)
            openClipsWindow?()
        case .toggleMicrophone:
            settings.capturesMicrophone.toggle()
            present(.success, settings.capturesMicrophone ? "Microphone on" : "Microphone off")
        }
    }

    /// Set by the app scene so keyboard actions can open windows.
    var openClipsWindow: (() -> Void)?

    // MARK: - Pause

    /// Stops or resumes capture without quitting.
    func togglePause() async {
        isPaused.toggle()
        Log.app.info("Buffer \(self.isPaused ? "paused" : "resumed", privacy: .public)")
        present(.success, isPaused ? "Buffer paused" : "Buffer resumed")
        await evaluateBufferPolicy()
    }

    private func applySettings() async {
        hotkeys.apply(settings.hotkeys)
        clips.setDirectory(settings.outputDirectory)
        games.selectedBundleIDs = Set(settings.selectedGames.map(\.bundleIdentifier))

        // Detection also runs under `.always`, because window-only capture needs
        // to know which app to point at even when the policy is not what decides
        // whether to buffer.
        if settings.bufferPolicy == .manual {
            games.stop()
        } else {
            games.start()
        }

        await capture.reconfigure(settings: settings.captureSnapshot, target: currentTarget)
        await evaluateBufferPolicy()
    }

    /// What capture should be pointed at right now.
    ///
    /// Window mode needs a game to aim at; with none detected it falls back to
    /// the display so the buffer still holds something useful.
    private var currentTarget: CaptureTarget {
        guard settings.captureMode == .gameWindow, let game = games.currentGame else {
            return .display(nil)
        }
        return .applicationWindow(pid: game.processIdentifier, name: game.name)
    }

    // MARK: - Buffer policy

    /// Decides whether the buffer should be running right now, and makes it so.
    ///
    /// This is the only place capture is started or stopped, so the answer can
    /// never be arrived at from two directions at once.
    func evaluateBufferPolicy() async {
        guard permissions.isAuthorized else {
            if capture.state.isActive { await capture.stop() }
            return
        }

        // Pause overrides every policy. Someone who paused deliberately does not
        // want a game launching to undo it.
        guard !isPaused else {
            if capture.state.isActive { await capture.stop() }
            return
        }

        let shouldRun = switch settings.bufferPolicy {
        case .always: true
        case .whilePlaying: games.isGameRunning
        case .manual: isManuallyArmed
        }

        if shouldRun, !capture.state.isActive {
            await capture.start(settings: settings.captureSnapshot, target: currentTarget)
        } else if !shouldRun, capture.state.isActive {
            await capture.stop()
        } else if shouldRun {
            // Already running, but the game may have changed — switching titles,
            // or a game launching while the display was being captured. In
            // window mode that means aiming somewhere new.
            await capture.reconfigure(settings: settings.captureSnapshot, target: currentTarget)
        }
    }

    /// Arms or disarms the buffer by hand.
    ///
    /// Only meaningful under `BufferPolicy.manual`; the other policies decide
    /// on their own and the menu bar hides this control for them.
    func toggleBuffer() async {
        isManuallyArmed.toggle()
        await evaluateBufferPolicy()
    }

    // MARK: - Saving

    /// Writes the buffer to disk. Bound to the global hotkey and the menu item.
    ///
    /// - Parameter seconds: how much of the buffer to keep, counting back from
    ///   now. `nil` saves everything buffered. Trimming happens on the snapshot
    ///   before writing, so asking for the last 15 seconds of a ten-minute
    ///   buffer costs nothing extra.
    func saveReplay(seconds: Double? = nil) async {
        guard !isSavingClip else { return }

        guard permissions.isAuthorized else {
            present(.failure, "Screen Recording permission is needed first.")
            return
        }
        guard capture.state.isActive, let snapshot = capture.snapshot(), !snapshot.isEmpty else {
            present(.failure, "Nothing is buffered yet.")
            await notifications.failure("The replay buffer isn't running.")
            return
        }
        guard clips.ensureDirectoryExists() else {
            present(.failure, clips.storageError ?? "The clips folder isn't writable.")
            return
        }

        // A clip that runs the disk to zero would corrupt itself and everything
        // else being written. Refuse early, while there is still room to explain.
        if let available = clips.availableCapacity, available < 512 * 1024 * 1024 {
            present(.failure, "Not enough disk space to save a clip.")
            await notifications.failure("Your disk is almost full.")
            return
        }

        isSavingClip = true
        defer { isSavingClip = false }

        let trimmed = seconds.map { snapshot.trimmed(toLast: $0) } ?? snapshot
        guard !trimmed.isEmpty else {
            present(.failure, "Not enough buffered yet for that length.")
            return
        }

        let gameName = games.currentGame?.name
        let destination = clips.destinationURL(gameName: gameName)

        do {
            try await clipWriter.write(trimmed, to: destination)

            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let clip = Clip(
                url: destination,
                createdAt: .now,
                fileSize: Int64(size),
                duration: trimmed.duration
            )

            clips.insert(clip)
            metadata.setGameName(gameName, for: destination)
            present(.success, "Saved \(Formatters.duration(clip.duration)) clip")

            await notifications.clipSaved(
                clip,
                showsAlert: settings.showsNotifications,
                playsSound: settings.playsSoundOnSave
            )

            Log.storage.info("Saved clip: \(clip.name, privacy: .public)")

            // Copy now rather than after compressing. A background re-encode
            // takes tens of seconds, and waiting for it meant pasting straight
            // after the "Saved" toast produced nothing at all.
            if settings.copiesToClipboard {
                clips.copyFile(clip)
            }

            // Compression runs after the clip is safely on disk, so a slow
            // re-encode can never delay the save or lose the moment.
            if settings.compression.isEnabled {
                Task { await compress(clip) }
            }
        } catch {
            // Never leave a half-written file behind to be mistaken for a clip.
            try? FileManager.default.removeItem(at: destination)

            let message = error.localizedDescription
            Log.storage.error("Save failed: \(message, privacy: .public)")
            present(.failure, message)
            await notifications.failure(message)
        }
    }

    /// Re-encodes a clip in the background according to the compression setting.
    private func compress(_ clip: Clip) async {
        let settings = self.settings.compression
        let captureBitrate = capture.activeConfiguration?.bitrate ?? 12_000_000

        do {
            let result = try await compressor.compress(
                clip.url,
                settings: settings,
                captureBitrate: captureBitrate
            )

            // Metadata follows the file when the original is replaced, and is
            // copied across when a separate compressed file is produced, so a
            // favourited clip stays favourited either way.
            if result.replacedOriginal {
                await clips.refresh()
            } else if result.url != clip.url {
                metadata.setGameName(metadata.gameName(for: clip.url), for: result.url)
                await clips.refresh()
            }

            let saved = clip.fileSize - result.byteCount
            if saved > 0 {
                present(.success, "Compressed to \(Formatters.fileSize.string(fromByteCount: result.byteCount))")
            }

            // The compressed copy is the shareable one, so it takes over the
            // clipboard from the original that was copied at save time.
            if self.settings.copiesToClipboard {
                clips.replaceCopy(of: clip.url, with: result.url)
            }

            Log.storage.info("Compressed \(clip.name, privacy: .public) to \(result.byteCount / 1_000_000, privacy: .public)MB")
        } catch {
            Log.storage.error("Compression failed: \(error.localizedDescription, privacy: .public)")
            present(.failure, "Couldn't compress \(clip.name).")
            // The uncompressed clip is already on the clipboard and is still
            // worth having, so there is nothing to undo here.
        }
    }

    // MARK: - Retention

    /// Applies the retention policy. Runs once at launch — enough for a
    /// menu bar app that is typically restarted with the machine; a periodic
    /// re-sweep for month-long uptimes is deliberately not worth a timer.
    func applyRetentionPolicy() async {
        guard settings.retention != .never else { return }

        await clips.refresh()
        let removed = RetentionSweeper.sweep(
            clips: clips.clips,
            rules: RetentionSweeper.Rules(
                policy: settings.retention,
                keepsFavorites: settings.retentionKeepsFavorites,
                keepsNamed: settings.retentionKeepsNamed
            ),
            metadata: metadata,
            store: clips
        )
        if removed > 0 {
            present(.success, "Moved \(removed) old clip\(removed == 1 ? "" : "s") to the Trash")
        }
    }

    private func revealClip(at url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows a transient message, replacing whatever was there.
    ///
    /// One timer, cancelled and restarted per message. Giving each its own let
    /// an earlier timer clear a later message, reproducible by triggering the
    /// same text twice: the guard compared text rather than identity.
    private func present(_ kind: StatusMessage.Kind, _ text: String) {
        lastMessage = StatusMessage(kind: kind, text: text)

        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.lastMessage = nil
            self.messageTask = nil
        }
    }

    // MARK: - Live statistics

    /// Starts polling buffer occupancy. Driven by the menu bar panel's
    /// lifecycle so nothing ticks while the UI is closed.
    func beginStatisticsUpdates() {
        guard statisticsTask == nil else { return }
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.bufferStatistics = self.capture.statistics
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func endStatisticsUpdates() {
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    // MARK: - Derived state for the UI

    /// One-line summary of what the app is doing, shown in the panel.
    var statusText: String {
        if !permissions.isAuthorized { return "Screen Recording permission needed" }

        switch capture.state {
        case .running:
            let seconds = Int(bufferedSeconds.rounded())
            let target = settings.replayDuration.seconds
            return Double(seconds) >= target
                ? "Buffering the last \(settings.replayDuration.shortLabel)"
                : "Filling buffer — \(Formatters.duration(bufferedSeconds)) of \(settings.replayDuration.shortLabel)"
        case .starting:
            return "Starting…"
        case .recovering:
            return "Reconnecting…"
        case .failed(let reason):
            return reason
        case .idle:
            if isPaused { return "Paused" }
            switch settings.bufferPolicy {
            case .whilePlaying: return "Waiting for a game"
            case .manual: return "Buffer is off"
            case .always: return "Idle"
            }
        }
    }

    var isBuffering: Bool { capture.state == .running }

    /// Audio is on, capture is running, and the buffer has filled long enough
    /// that silence is suspicious rather than merely early.
    ///
    /// The delay matters: audio only flows while something is playing, so a
    /// game on a loading screen would otherwise trip this immediately.
    var isMissingAudio: Bool {
        isBuffering
            && settings.capturesSystemAudio
            && !capture.isReceivingAudio
            && bufferStatistics.bufferedSeconds > 8
    }

    /// What capture is currently pointed at, phrased for the menu bar panel.
    ///
    /// Worth showing because window mode falls back to the display silently;
    /// without this the user could not tell which one they are getting.
    var captureTargetText: String {
        switch capture.target {
        case .applicationWindow(_, let name):
            "Recording \(name)'s window"
        case .display:
            settings.captureMode == .gameWindow
                ? "Recording the display — no game window found"
                : "Recording the entire display"
        }
    }

    /// What the menu bar icon should convey.
    enum MenuBarState: Equatable, Sendable {
        case needsPermission
        case buffering
        case saving
        case idle

        var symbolName: String {
            switch self {
            case .needsPermission: "exclamationmark.triangle"
            case .buffering: "record.circle.fill"
            case .saving: "arrow.down.circle.fill"
            case .idle: "record.circle"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .needsPermission: "Vestige — permission needed"
            case .buffering: "Vestige — buffering"
            case .saving: "Vestige — saving clip"
            case .idle: "Vestige — idle"
            }
        }
    }

    var menuBarState: MenuBarState {
        if isSavingClip { return .saving }
        if !permissions.isAuthorized { return .needsPermission }
        return isBuffering ? .buffering : .idle
    }

    /// Seconds of footage available to save, as the user should understand it.
    ///
    /// The buffer holds slightly more than the configured duration, since it
    /// can only discard whole keyframe segments. Reporting the raw figure made
    /// the readout climb past its own limit (60 → 61 → 62) and snap back as
    /// each segment aged out. The surplus still ends up in the clip; it just
    /// stops being advertised as instability.
    var bufferedSeconds: Double {
        min(bufferStatistics.bufferedSeconds, settings.replayDuration.seconds)
    }

    /// How full the buffer is, 0–1, for the progress ring.
    var bufferProgress: Double {
        guard settings.replayDuration.seconds > 0 else { return 0 }
        return min(1, bufferStatistics.bufferedSeconds / settings.replayDuration.seconds)
    }
}
