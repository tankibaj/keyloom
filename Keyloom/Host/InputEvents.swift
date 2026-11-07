import Foundation

/// Where a keyboard event came from, decided from event metadata only (never from its text).
enum InputOrigin: Equatable, Sendable {
    /// No originating process: presumed hardware keyboard.
    case physical
    /// Posted by another process (automation, another expander). Never typed text we can trust.
    case synthetic
    /// Posted by Keyloom itself (its own insertion keystrokes, tagged with `OwnEvents.marker`). Always ignored.
    case ownProcess
}

enum OwnEvents {
    /// `eventSourceUserData` value stamped on every event Keyloom posts, so the tap can tell them from the user's.
    static let marker: Int64 = 0x4B4C_4F4F_4D01
}

/// What a key event carried. Built lazily by the tap, and only after every privacy gate has passed.
struct KeyContent: Equatable, Sendable {
    var units: [UInt16]
    var keyCode: UInt16
    /// Command or Control held: a shortcut, not typing. Option alone is how German layouts type `@`, `[`, `{`.
    var hasCommandOrControl: Bool

    private static let navigationKeyCodes: Set<UInt16> = [
        36, 48, 51, 53, 71, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    /// Return, Tab, Delete, Escape, Home/End, paging, arrows, shortcuts, dead keys and function keys: what is
    /// in front of the caret is no longer what the matcher buffered.
    var breaksTyping: Bool {
        if hasCommandOrControl || units.isEmpty || Self.navigationKeyCodes.contains(keyCode) { return true }
        return units.contains { $0 < 0x20 || $0 == 0x7F || (0xF700...0xF8FF).contains($0) }
    }
}
