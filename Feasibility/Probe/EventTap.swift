import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Real input environment: secure event input, input-method detection, waiting.
final class SystemEnvironment: InputEnvironment {
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Fail closed on any input method: the probe cannot see marked text, so
    /// only a plain keyboard layout counts as non-composing.
    var isComposingInput: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, "TISPropertyInputSourceType" as CFString)
        else { return true }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type != "TISTypeKeyboardLayout"
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return true
    }
}

struct PermissionStatus: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool

    static func current() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    var allGranted: Bool { accessibility && inputMonitoring }

    /// Prompts only the missing permissions; called from a button, never at launch.
    static func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }
}

/// What the tap forwards, in arrival order.
enum TapEvent: Equatable {
    case key(KeyInput)
    /// A keyboard event seen while secure input was on: dropped unread, but the gap is reported.
    case secureKeySuppressed
    case navigation
}

/// Listen-only session tap that forwards key and navigation events to the
/// engine on the main queue. It never modifies or blocks events and keeps no text.
final class EventTap {
    var onEvent: ((TapEvent) -> Void)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Bumped on stop: events queued before it must not reach a later run.
    private var generation = 0
    private let isSecureInput: () -> Bool
    private let enqueue: (@escaping () -> Void) -> Void

    var isRunning: Bool { port != nil }

    /// The parameters are the test seams for the secure-input check and the queue hop.
    init(
        isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.isSecureInput = isSecureInput
        self.enqueue = enqueue
    }

    func start() -> Bool {
        guard port == nil else { return true }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        for type in types { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        source = runLoopSource
        return true
    }

    func stop() {
        generation += 1
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            forward(Self.route(secure: isSecureInput(), classify: { Self.classify(event) }))
        default:
            forward(.navigation)
        }
    }

    /// Secure keyboard events are dropped before their Unicode is read.
    static func route(secure: Bool, classify: () -> KeyInput) -> TapEvent {
        secure ? .secureKeySuppressed : .key(classify())
    }

    /// Queues in arrival order, so a suppression marker sits between the keys around it.
    func forward(_ event: TapEvent) {
        let captured = generation
        enqueue { [weak self] in
            guard let self, self.generation == captured else { return }
            self.onEvent?(event)
        }
    }

    static func classify(_ event: CGEvent) -> KeyInput {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let origin: InputOrigin
        if sourcePID == Int64(getpid()) {
            origin = .ownProcess
        } else {
            origin = sourcePID == 0 ? .physical : .synthetic
        }
        return KeyInput(
            units: Array(chars.prefix(length)),
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            isShortcut: !event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]),
            origin: origin
        )
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
