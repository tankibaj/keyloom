import AppKit
import Carbon.HIToolbox
import Observation

/// The picker shortcut recorder. The view feeds it key presses while recording; the host registers the result and
/// reports a conflict, which stays visible next to the shortcut.
@MainActor @Observable
final class ShortcutSettingsModel {
    private(set) var isRecording = false
    private var hint: String?
    @ObservationIgnored private let host: InputHostController

    init(host: InputHostController) {
        self.host = host
    }

    /// The saved shortcut, even when macOS refused it (the message says so).
    var current: ShortcutConfig {
        switch host.status.shortcut {
        case .registered(let config), .conflict(let config), .failed(let config, _), .invalid(let config): config
        case .unregistered: .defaultShortcut
        }
    }

    var display: String { ShortcutDisplay.string(for: current) }
    var message: String? { hint ?? ShortcutDisplay.message(for: host.status.shortcut) }

    func beginRecording() {
        hint = nil
        isRecording = true
    }

    func cancelRecording() {
        hint = nil
        isRecording = false
    }

    /// True when the key was consumed. Escape alone cancels; a combination without Command, Control or Option is
    /// refused and recording continues.
    @discardableResult
    func handleKey(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isRecording else { return false }
        let carbon = Self.carbonModifiers(modifiers)
        if keyCode == UInt32(kVK_Escape), carbon == 0 {
            cancelRecording()
            return true
        }
        let config = ShortcutConfig(keyCode: keyCode, modifiers: carbon)
        guard config.isValid else {
            hint = ShortcutDisplay.message(for: .invalid(config))
            return true
        }
        hint = nil
        isRecording = false
        host.setShortcut(config)
        return true
    }

    func reset() {
        cancelRecording()
        host.setShortcut(.defaultShortcut)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}
