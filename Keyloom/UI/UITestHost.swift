import Foundation

// Inert OS boundaries for `--keyloom-ui-test` (and for the app hosting XCTest): no event tap, no hotkey, no
// Accessibility or Input Monitoring prompts, no real clipboard. The whole UI can then be driven by XCUITest or
// a reviewer without granting anything. Permissions read as not granted, so the Settings permission rows and
// the picker's Copy-only path are what the tester sees.

@MainActor
private final class InertPermissions: PermissionChecking {
    func current() -> PermissionStatus { PermissionStatus(accessibility: false, inputMonitoring: false, postEvents: false) }
    func request() {}
}

@MainActor
private final class InertEnvironment: InputEnvironment {
    var isSecureInputActive: Bool { false }
    var isComposingInput: Bool { false }
}

@MainActor
private final class InertWorkspace: WorkspaceInfo {
    var frontmostBundleID: String? { nil }
}

@MainActor
private final class InertDestination: DestinationAccess {
    func focusToken() -> FocusToken? { nil }
    func snapshot() -> FieldSnapshot? { nil }
    func activate(_ token: FocusToken) async -> Bool { false }
    func replace(range: NSRange, with text: String, bound: FieldSnapshot) -> WriteResult { .failed }
    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult { .failed }
    func restoreSelection(_ caret: NSRange, ifSelected selected: NSRange, in token: FocusToken) -> WriteResult { .failed }
}

/// A clipboard that lives in memory, so Copy can be exercised without touching the tester's real clipboard.
@MainActor
private final class MemoryPasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private var text: String?

    func plainText() -> String? { text }
    func snapshot() -> PasteboardItems? { [] }

    func write(plain: String, rtf: Data?) -> Int {
        text = plain
        changeCount += 1
        return changeCount
    }

    func restore(_ items: PasteboardItems, ifChangeCount expected: Int) -> PasteboardRestore { .ownershipLost }
}

@MainActor
private final class InertKeys: PasteKeyPosting {
    func postPaste() -> Bool { false }
}

@MainActor
private final class InertTap: EventTapControlling {
    let isRunning = false
    func start() -> Bool { false }
    func stop() {}
}

@MainActor
private final class InertHotKeys: HotKeyRegistering {
    func register(_ config: ShortcutConfig, onPress: @escaping @MainActor () -> Void) -> HotKeyRegistration { .registered }
    func unregister() {}
}

extension HostDependencies {
    static func uiTest() -> HostDependencies {
        HostDependencies(
            destination: InertDestination(), pasteboard: MemoryPasteboard(), keys: InertKeys(), permissions: InertPermissions(),
            environment: InertEnvironment(), workspace: InertWorkspace(), hotKeys: InertHotKeys(), makeTap: { _ in InertTap() },
            settle: { _ in }, ownBundleID: Bundle.main.bundleIdentifier, permissionPollInterval: nil)
    }
}
