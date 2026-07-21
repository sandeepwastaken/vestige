import Carbon.HIToolbox
import Foundation

/// Everything Vestige can be driven by from the keyboard.
///
/// Each case owns a stable `id` used both as its `UserDefaults` key and as its
/// Carbon hot key identifier, so bindings survive reordering this enum.
enum HotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case saveReplay
    case saveLast15
    case saveLast30
    case pauseResume
    case openClips
    case toggleMicrophone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .saveReplay: "Save replay"
        case .saveLast15: "Save last 15 seconds"
        case .saveLast30: "Save last 30 seconds"
        case .pauseResume: "Pause or resume buffering"
        case .openClips: "Open clips"
        case .toggleMicrophone: "Toggle microphone"
        }
    }

    var detail: String {
        switch self {
        case .saveReplay: "Saves whatever the replay length is set to."
        case .saveLast15: "Saves a short clip regardless of the replay length."
        case .saveLast30: "Saves a medium clip regardless of the replay length."
        case .pauseResume: "Stops capturing without quitting Vestige."
        case .openClips: "Opens the clip library."
        case .toggleMicrophone: "Turns microphone capture on or off mid-session."
        }
    }

    /// Carbon hot key IDs must be unique within the process.
    var carbonID: UInt32 {
        switch self {
        case .saveReplay: 1
        case .saveLast15: 2
        case .saveLast30: 3
        case .pauseResume: 4
        case .openClips: 5
        case .toggleMicrophone: 6
        }
    }

    /// Defaults are chosen to be unlikely to collide with games or the system.
    /// Only saving is bound out of the box — the rest are opt-in, so Vestige
    /// claims as little of the keyboard as possible.
    var defaultBinding: HotkeyBinding? {
        switch self {
        case .saveReplay:
            HotkeyBinding(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | cmdKey))
        case .saveLast15, .saveLast30, .pauseResume, .openClips, .toggleMicrophone:
            nil
        }
    }

    /// Seconds this action saves, or `nil` for "whatever the setting says".
    var saveDuration: Double? {
        switch self {
        case .saveLast15: 15
        case .saveLast30: 30
        default: nil
        }
    }
}
