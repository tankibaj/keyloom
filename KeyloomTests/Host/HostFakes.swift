import Foundation
@testable import Keyloom

// Fakes for the OS boundaries only (secure input, input methods, permissions, workspace, AX field, pasteboard,
// key posting, hotkeys). Passing tests prove decision logic, not real destination behaviour; live runs do that.

@MainActor
final class FakeInputEnvironment: InputEnvironment {
    var isSecureInputActive = false
    var isComposingInput = false
}

@MainActor
final class FakeWorkspace: WorkspaceInfo {
    var frontmostBundleID: String? = "com.apple.TextEdit"
}

@MainActor
final class FakePermissions: PermissionChecking {
    var status = PermissionStatus(accessibility: true, inputMonitoring: true, postEvents: true)
    private(set) var requestCount = 0
    func current() -> PermissionStatus { status }
    func request() { requestCount += 1 }
}

/// Records whether a lazily-read value was ever read.
final class ReadFlag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
