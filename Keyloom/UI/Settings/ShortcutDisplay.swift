import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// How a global shortcut and its registration state read to the user (menu bar, picker and Settings).
enum ShortcutDisplay {
    /// Control, Option, Shift, Command in the system's order, then the key: "⌃⌥Space".
    static func string(for config: ShortcutConfig) -> String {
        var text = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] where config.modifiers & UInt32(flag) != 0 {
            text += symbol
        }
        return text + keyName(config.keyCode)
    }

    /// Nil when the shortcut works (or is not set up yet); otherwise what is wrong and what to do.
    static func message(for state: ShortcutState) -> String? {
        switch state {
        case .unregistered, .registered:
            nil
        case .conflict(let config):
            "\(string(for: config)) is already used by another app or macOS, so the picker shortcut is off. Choose another in Settings, or open the picker from the menu bar."
        case .failed(let config, _):
            "macOS refused \(string(for: config)) for the picker. Choose another shortcut in Settings, or open the picker from the menu bar."
        case .invalid(let config):
            "\(string(for: config)) needs Command, Control or Option so it doesn’t take over normal typing."
        }
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ keyCode: UInt32) -> String {
        named[Int(keyCode)] ?? layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
    }

    /// The character the current keyboard layout prints on that key.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer in
            UCKeyTranslate(buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           CGEventSource(stateID: .combinedSessionState)?.keyboardType ?? 0, OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead,
                           characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
