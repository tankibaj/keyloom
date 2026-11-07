import AppKit
import ApplicationServices

/// Listen-only session tap feeding `InputHost` on the main run loop. It never modifies or blocks an event and
/// keeps no text. The callback does no Accessibility, database or cloud work (see `InputHost`).
@MainActor
final class EventTap {
    private let host: InputHost
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    init(host: InputHost) {
        self.host = host
    }

    /// False when macOS refuses the tap (Input Monitoring not granted).
    func start() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: eventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        source = runLoopSource
        host.invalidate()
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        host.invalidate()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Events were lost while disabled: whatever was buffered may no longer be contiguous.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            host.invalidate()
        case .keyDown:
            host.handleKeyDown(origin: Self.origin(of: event)) { Self.content(of: event) }
        default:
            host.invalidate()
        }
    }

    /// Metadata only; the key's text is not touched here.
    private static func origin(of event: CGEvent) -> InputOrigin {
        if event.getIntegerValueField(.eventSourceUserData) == OwnEvents.marker { return .ownProcess }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if sourcePID == Int64(getpid()) { return .ownProcess }
        return sourcePID == 0 ? .physical : .synthetic
    }

    private static func content(of event: CGEvent) -> KeyContent {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        return KeyContent(
            units: Array(chars.prefix(length)),
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            hasCommandOrControl: !event.flags.isDisjoint(with: [.maskCommand, .maskControl]))
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
        // The run-loop source lives on the main run loop, so this callback is on the main thread.
        nonisolated(unsafe) let unsafeEvent = event
        MainActor.assumeIsolated { tap.handle(type: type, event: unsafeEvent) }
    }
    return Unmanaged.passUnretained(event)
}
