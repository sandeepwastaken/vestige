import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut, stored as a virtual key code plus Carbon
/// modifier flags.
///
/// Key *codes* are physical positions, not characters — code 15 is wherever "R"
/// sits on a US layout and wherever something else sits on AZERTY. The label
/// shown in the UI is therefore resolved against the user's live keyboard layout
/// rather than a hardcoded table.
struct HotkeyBinding: Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// A shortcut with no modifiers would swallow ordinary typing system-wide.
    var isValid: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0
    }

    // MARK: - Persistence

    /// Packs both halves into one integer. Carbon modifier masks all fit below
    /// 1 << 16 and key codes below 1 << 8, so the two never collide.
    var storageValue: Int {
        Int(keyCode) | (Int(carbonModifiers) << 16)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(storageValue: Int) {
        guard storageValue > 0 else { return nil }
        self.keyCode = UInt32(storageValue & 0xFFFF)
        self.carbonModifiers = UInt32((storageValue >> 16) & 0xFFFF)
    }

    // MARK: - Display

    /// e.g. "⌥⌘R". Modifier order follows the Human Interface Guidelines.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.label(for: keyCode)
    }

    /// Human-readable name for a virtual key code.
    static func label(for keyCode: UInt32) -> String {
        if let special = specialKeyLabels[Int(keyCode)] {
            return special
        }
        if let character = layoutCharacter(for: keyCode) {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Translates a key code through the active keyboard layout so the label
    /// matches what is actually printed on the user's keys.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data

        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers: we want the unshifted legend
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// Keys that have no printable legend, or whose legend is a symbol.
    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}

// MARK: - AppKit bridging

import AppKit

extension HotkeyBinding {
    /// Builds a binding from a captured `NSEvent`, for the shortcut recorder.
    init?(event: NSEvent) {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        guard binding.isValid else { return nil }
        self = binding
    }
}
