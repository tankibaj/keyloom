import Carbon.HIToolbox
import Foundation

/// A global shortcut as a virtual key code plus Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`,
/// `shiftKey`). Persisted by the host preferences.
struct ShortcutConfig: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    /// A shortcut with only Shift (or nothing) would hijack ordinary typing, so one of Command, Control or
    /// Option is required.
    var isValid: Bool { modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 }
}

enum HotKeyRegistration: Equatable, Sendable {
    case registered
    /// Another app or the system already owns this combination.
    case conflict
    case failed(Int32)
}

enum ShortcutState: Equatable, Sendable {
    case unregistered
    case registered(ShortcutConfig)
    case conflict(ShortcutConfig)
    case failed(ShortcutConfig, status: Int32)
    case invalid(ShortcutConfig)
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Registers `config` (replacing any earlier registration) and calls `onPress` on the main actor.
    func register(_ config: ShortcutConfig, onPress: @escaping @MainActor () -> Void) -> HotKeyRegistration
    func unregister()
}

/// Owns the one global shortcut. A failed change leaves the previous shortcut working and reports why.
@MainActor
final class ShortcutManager {
    private(set) var state: ShortcutState = .unregistered
    private var active: ShortcutConfig?
    private let registrar: HotKeyRegistering
    private let onPress: @MainActor () -> Void

    init(registrar: HotKeyRegistering, onPress: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.onPress = onPress
    }

    @discardableResult
    func apply(_ config: ShortcutConfig) -> ShortcutState {
        guard config.isValid else {
            state = .invalid(config)
            return state
        }
        let previous = active
        registrar.unregister()
        switch registrar.register(config, onPress: onPress) {
        case .registered:
            active = config
            state = .registered(config)
        case .conflict:
            restore(previous)
            state = .conflict(config)
        case .failed(let status):
            restore(previous)
            state = .failed(config, status: status)
        }
        return state
    }

    func remove() {
        registrar.unregister()
        active = nil
        state = .unregistered
    }

    private func restore(_ previous: ShortcutConfig?) {
        guard let previous, registrar.register(previous, onPress: onPress) == .registered else {
            active = nil
            return
        }
        active = previous
    }
}

/// `RegisterEventHotKey`: a system hotkey that needs no Accessibility or Input Monitoring permission and is
/// delivered only for its exact combination, so it never sees other keystrokes.
@MainActor
final class CarbonHotKeys: HotKeyRegistering {
    private static let signature: OSType = 0x4B4C_4F4D  // 'KLOM'
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?

    func register(_ config: ShortcutConfig, onPress: @escaping @MainActor () -> Void) -> HotKeyRegistration {
        unregister()
        let installed = installHandlerIfNeeded()
        guard installed == noErr else { return .failed(installed) }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &reference)
        switch status {
        case noErr:
            hotKey = reference
            self.onPress = onPress
            return .registered
        case OSStatus(eventHotKeyExistsErr):
            return .conflict
        default:
            return .failed(status)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        onPress = nil
    }

    fileprivate func fire() { onPress?() }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handler == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let keys = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
    // The application event target dispatches on the main thread.
    MainActor.assumeIsolated { keys.fire() }
    return noErr
}
