import AppKit
import Carbon.HIToolbox
import Observation

/// Registers Vestige's global shortcuts with the window server.
///
/// Carbon's `RegisterEventHotKey` is used rather than a `CGEventTap` for one
/// decisive reason: it needs no Accessibility permission. An event tap would
/// force users through a second TCC prompt and would see every keystroke they
/// type. This API only ever tells us that one of our own registered
/// combinations fired, which is both better for privacy and far less work per
/// keystroke — relevant when the user is mid-game.
@MainActor
@Observable
final class HotkeyManager {
    /// Actions whose shortcut could not be claimed, usually because another app
    /// already owns the combination.
    private(set) var failedActions: Set<HotkeyAction> = []

    private let registration = CarbonRegistration()
    private var bindings: [HotkeyAction: HotkeyBinding] = [:]

    /// Invoked on the main actor when a shortcut fires.
    var onAction: ((HotkeyAction) -> Void)?

    private static let signature: OSType = 0x56455354 // 'VEST'

    // MARK: - Registration

    /// Applies a complete set of bindings, registering and unregistering only
    /// what actually changed.
    func apply(_ newBindings: [HotkeyAction: HotkeyBinding]) {
        installEventHandlerIfNeeded()

        for action in HotkeyAction.allCases {
            let desired = newBindings[action]
            guard desired != bindings[action] else { continue }

            registration.unregister(action)
            bindings[action] = nil
            failedActions.remove(action)

            guard let desired, desired.isValid else { continue }

            if registration.register(desired, for: action, signature: Self.signature) {
                bindings[action] = desired
                Log.hotkeys.info("Registered \(desired.displayString, privacy: .public) for \(action.rawValue, privacy: .public)")
            } else {
                failedActions.insert(action)
                Log.hotkeys.error("Could not register \(desired.displayString, privacy: .public) for \(action.rawValue, privacy: .public)")
            }
        }
    }

    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        bindings[action]
    }

    /// True when two actions are bound to the same combination, which the UI
    /// surfaces rather than silently letting one of them lose.
    func conflicts(in candidate: [HotkeyAction: HotkeyBinding]) -> Set<HotkeyAction> {
        var seen: [HotkeyBinding: HotkeyAction] = [:]
        var conflicting: Set<HotkeyAction> = []

        for (action, binding) in candidate.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let existing = seen[binding] {
                conflicting.insert(existing)
                conflicting.insert(action)
            } else {
                seen[binding] = action
            }
        }
        return conflicting
    }

    private func installEventHandlerIfNeeded() {
        guard registration.eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &registration.eventHandler
        )

        if status != noErr {
            Log.hotkeys.error("Failed to install hot key handler (error \(status, privacy: .public))")
        }
    }

    /// The handler is installed on the shared event dispatcher, so it sees hot
    /// keys registered by other components too. Without the signature check a
    /// foreign combination that happened to share one of our small integer ids
    /// would fire the matching Vestige action.
    fileprivate func handleHotkey(id: EventHotKeyID) {
        guard id.signature == Self.signature,
              let action = HotkeyAction.allCases.first(where: { $0.carbonID == id.id })
        else { return }
        onAction?(action)
    }
}

/// Owns the raw Carbon handles.
///
/// Kept separate from `HotkeyManager` purely so that teardown can happen in a
/// nonisolated `deinit`: releasing these is the one piece of cleanup that must
/// not depend on a caller remembering to ask for it.
private final class CarbonRegistration: @unchecked Sendable {
    var eventHandler: EventHandlerRef?
    private var hotKeys: [HotkeyAction: EventHotKeyRef] = [:]

    func register(_ binding: HotkeyBinding, for action: HotkeyAction, signature: OSType) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: action.carbonID)

        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else { return false }
        hotKeys[action] = reference
        return true
    }

    func unregister(_ action: HotkeyAction) {
        guard let reference = hotKeys.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(reference)
    }

    deinit {
        for reference in hotKeys.values {
            UnregisterEventHotKey(reference)
        }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

/// Carbon dispatches hot keys on the main thread, which is what makes the
/// `assumeIsolated` hop below sound rather than merely convenient.
private func hotkeyEventHandler(
    _ handlerRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleHotkey(id: hotKeyID)
    }
    return noErr
}
