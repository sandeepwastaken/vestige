import Foundation
import Observation

/// User-facing preferences, persisted to `UserDefaults`.
///
/// Every property writes through on `didSet`, so there is no explicit "save"
/// step and no window in which an in-memory change can be lost to a crash.
/// The store is `@MainActor` because it is bound directly to SwiftUI controls;
/// components that need settings off the main actor receive an immutable
/// snapshot (see `CaptureSettings`) rather than a reference.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    // MARK: - Recording

    var replayDuration: ReplayDuration {
        didSet { defaults.set(replayDuration.rawValue, forKey: Key.replayDuration) }
    }

    /// Records the microphone alongside system audio. Off by default: a replay
    /// buffer that silently captures the room would be a nasty surprise.
    var capturesMicrophone: Bool {
        didSet { defaults.set(capturesMicrophone, forKey: Key.capturesMicrophone) }
    }

    var resolution: VideoResolution {
        didSet { defaults.set(resolution.rawValue, forKey: Key.resolution) }
    }

    var frameRate: FrameRate {
        didSet { defaults.set(frameRate.rawValue, forKey: Key.frameRate) }
    }

    var codec: VideoCodec {
        didSet { defaults.set(codec.rawValue, forKey: Key.codec) }
    }

    var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: Key.capturesSystemAudio) }
    }

    var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) }
    }

    /// Apps the user nominated as games. Encoded as JSON because the value is a
    /// list of structs rather than the property-list primitives `UserDefaults`
    /// handles natively.
    var selectedGames: [SelectedGame] {
        didSet {
            guard let data = try? JSONEncoder().encode(selectedGames) else { return }
            defaults.set(data, forKey: Key.selectedGames)
        }
    }

    // MARK: - Behaviour

    var bufferPolicy: BufferPolicy {
        didSet { defaults.set(bufferPolicy.rawValue, forKey: Key.bufferPolicy) }
    }

    var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path(percentEncoded: false), forKey: Key.outputDirectory) }
    }

    var showsNotifications: Bool {
        didSet { defaults.set(showsNotifications, forKey: Key.showsNotifications) }
    }

    var playsSoundOnSave: Bool {
        didSet { defaults.set(playsSoundOnSave, forKey: Key.playsSoundOnSave) }
    }

    /// All keyboard shortcuts, keyed by action. Actions absent from the map are
    /// simply unbound.
    var hotkeys: [HotkeyAction: HotkeyBinding] {
        didSet {
            let encoded = hotkeys.reduce(into: [String: Int]()) { result, entry in
                result[entry.key.rawValue] = entry.value.storageValue
            }
            defaults.set(encoded, forKey: Key.hotkeys)
        }
    }

    var compression: CompressionSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(compression) else { return }
            defaults.set(data, forKey: Key.compression)
        }
    }

    /// Copies the saved clip to the clipboard so it can be pasted straight into
    /// Discord or a message. When a compressed copy is produced, that is the one
    /// copied — it is the version meant for sharing.
    var copiesToClipboard: Bool {
        didSet { defaults.set(copiesToClipboard, forKey: Key.copiesToClipboard) }
    }

    var retention: RetentionPolicy {
        didSet { defaults.set(retention.rawValue, forKey: Key.retention) }
    }

    var retentionKeepsFavorites: Bool {
        didSet { defaults.set(retentionKeepsFavorites, forKey: Key.retentionKeepsFavorites) }
    }

    var retentionKeepsNamed: Bool {
        didSet { defaults.set(retentionKeepsNamed, forKey: Key.retentionKeepsNamed) }
    }

    var profiles: [CaptureProfile] {
        didSet {
            guard let data = try? JSONEncoder().encode(profiles) else { return }
            defaults.set(data, forKey: Key.profiles)
        }
    }

    var activeProfileID: UUID? {
        didSet { defaults.set(activeProfileID?.uuidString, forKey: Key.activeProfileID) }
    }

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        replayDuration = ReplayDuration(
            defaults.object(forKey: Key.replayDuration).flatMap { $0 as? Int } ?? 60
        )

        capturesMicrophone = defaults.object(forKey: Key.capturesMicrophone) as? Bool ?? false

        resolution = defaults.string(forKey: Key.resolution)
            .flatMap(VideoResolution.init(rawValue:)) ?? .p1080

        frameRate = defaults.object(forKey: Key.frameRate)
            .flatMap { $0 as? Int }
            .flatMap(FrameRate.init(rawValue:)) ?? .fps60

        codec = defaults.string(forKey: Key.codec)
            .flatMap(VideoCodec.init(rawValue:)) ?? .hevc

        capturesSystemAudio = defaults.object(forKey: Key.capturesSystemAudio) as? Bool ?? true

        captureMode = defaults.string(forKey: Key.captureMode)
            .flatMap(CaptureMode.init(rawValue:)) ?? .gameWindow

        selectedGames = defaults.data(forKey: Key.selectedGames)
            .flatMap { try? JSONDecoder().decode([SelectedGame].self, from: $0) } ?? []

        bufferPolicy = defaults.string(forKey: Key.bufferPolicy)
            .flatMap(BufferPolicy.init(rawValue:)) ?? .whilePlaying

        outputDirectory = defaults.string(forKey: Key.outputDirectory)
            .map { URL(fileURLWithPath: $0) } ?? Self.defaultOutputDirectory

        showsNotifications = defaults.object(forKey: Key.showsNotifications) as? Bool ?? true
        playsSoundOnSave = defaults.object(forKey: Key.playsSoundOnSave) as? Bool ?? true

        if let stored = defaults.dictionary(forKey: Key.hotkeys) as? [String: Int] {
            hotkeys = stored.reduce(into: [HotkeyAction: HotkeyBinding]()) { result, entry in
                guard let action = HotkeyAction(rawValue: entry.key),
                      let binding = HotkeyBinding(storageValue: entry.value)
                else { return }
                result[action] = binding
            }
        } else {
            // Migrates the single shortcut stored by earlier versions, so an
            // existing user's binding is not silently reset.
            let legacy = defaults.object(forKey: Key.legacySaveHotkey)
                .flatMap { $0 as? Int }
                .flatMap { HotkeyBinding(storageValue: $0) }

            hotkeys = HotkeyAction.allCases.reduce(into: [HotkeyAction: HotkeyBinding]()) { result, action in
                if action == .saveReplay, let legacy {
                    result[action] = legacy
                } else if let fallback = action.defaultBinding {
                    result[action] = fallback
                }
            }
        }

        compression = defaults.data(forKey: Key.compression)
            .flatMap { try? JSONDecoder().decode(CompressionSettings.self, from: $0) }
            ?? CompressionSettings()

        copiesToClipboard = defaults.object(forKey: Key.copiesToClipboard) as? Bool ?? false

        retention = defaults.string(forKey: Key.retention)
            .flatMap(RetentionPolicy.init(rawValue:)) ?? .never
        retentionKeepsFavorites = defaults.object(forKey: Key.retentionKeepsFavorites) as? Bool ?? true
        retentionKeepsNamed = defaults.object(forKey: Key.retentionKeepsNamed) as? Bool ?? true

        profiles = defaults.data(forKey: Key.profiles)
            .flatMap { try? JSONDecoder().decode([CaptureProfile].self, from: $0) }
            ?? CaptureProfile.builtIns()

        activeProfileID = defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:))
    }

    // MARK: - Profiles

    /// Overwrites every capture setting from a profile.
    func apply(_ profile: CaptureProfile) {
        replayDuration = ReplayDuration(profile.replayDurationSeconds)
        resolution = profile.resolution
        frameRate = profile.frameRate
        codec = profile.codec
        capturesSystemAudio = profile.capturesSystemAudio
        capturesMicrophone = profile.capturesMicrophone
        captureMode = profile.captureMode
        compression = profile.compression
        activeProfileID = profile.id
    }

    /// Builds a profile from the settings as they stand.
    func makeProfile(named name: String) -> CaptureProfile {
        CaptureProfile(
            name: name,
            replayDurationSeconds: replayDuration.rawValue,
            resolution: resolution,
            frameRate: frameRate,
            codec: codec,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            captureMode: captureMode,
            compression: compression
        )
    }

    /// Whether current settings still match the active profile. Editing a
    /// setting by hand detaches from the profile rather than silently
    /// redefining it.
    var matchesActiveProfile: Bool {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID })
        else { return false }

        var candidate = makeProfile(named: profile.name)
        candidate.id = profile.id
        return candidate == profile
    }

    /// `~/Movies/Vestige`, matching where Screenshot and QuickTime put recordings.
    static var defaultOutputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
        return movies.appending(path: "Vestige", directoryHint: .isDirectory)
    }

    /// An immutable, `Sendable` view of the settings that affect capture, safe
    /// to hand to the capture actor.
    var captureSnapshot: CaptureSettings {
        CaptureSettings(
            duration: replayDuration,
            resolution: resolution,
            frameRate: frameRate,
            codec: codec,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            captureMode: captureMode
        )
    }

    private enum Key {
        static let replayDuration = "replayDuration"
        static let resolution = "resolution"
        static let frameRate = "frameRate"
        static let codec = "codec"
        static let capturesSystemAudio = "capturesSystemAudio"
        static let capturesMicrophone = "capturesMicrophone"
        static let captureMode = "captureMode"
        static let selectedGames = "selectedGames"
        static let bufferPolicy = "bufferPolicy"
        static let outputDirectory = "outputDirectory"
        static let showsNotifications = "showsNotifications"
        static let playsSoundOnSave = "playsSoundOnSave"
        static let legacySaveHotkey = "saveHotkey"
        static let hotkeys = "hotkeys"
        static let compression = "compression"
        static let copiesToClipboard = "copiesToClipboard"
        static let retention = "retention"
        static let retentionKeepsFavorites = "retentionKeepsFavorites"
        static let retentionKeepsNamed = "retentionKeepsNamed"
        static let profiles = "profiles"
        static let activeProfileID = "activeProfileID"
    }
}

/// The subset of settings the capture pipeline needs, as an immutable value.
///
/// Passing a snapshot rather than the store keeps the pipeline free of main-actor
/// hops and makes "did the configuration change?" a simple `==`.
struct CaptureSettings: Equatable, Sendable {
    var duration: ReplayDuration
    var resolution: VideoResolution
    var frameRate: FrameRate
    var codec: VideoCodec
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var captureMode: CaptureMode
}
