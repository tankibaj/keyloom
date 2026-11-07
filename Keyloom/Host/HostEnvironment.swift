import AppKit
import ApplicationServices
import Carbon.HIToolbox

// The OS boundaries of the input host, as protocols so the decision logic is testable without a real keyboard.

struct PermissionStatus: Equatable, Sendable {
    var accessibility: Bool
    var inputMonitoring: Bool
    /// Only the explicit paste route posts events; plain AX insertion does not need it.
    var postEvents: Bool

    /// Reading keys and writing through Accessibility both need to be granted.
    var inputReady: Bool { accessibility && inputMonitoring }
}

@MainActor
protocol PermissionChecking: AnyObject {
    /// Read at each point of use, never cached by the caller across a mutation.
    func current() -> PermissionStatus
    /// Prompts the missing permissions; call from a button, never at launch.
    func request()
}

@MainActor
protocol InputEnvironment: AnyObject {
    var isSecureInputActive: Bool { get }
    /// An input method (not a plain layout) is active: composition cannot be ruled out.
    var isComposingInput: Bool { get }
}

@MainActor
protocol WorkspaceInfo: AnyObject {
    var frontmostBundleID: String? { get }
}

@MainActor
final class SystemPermissions: PermissionChecking {
    func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess(),
                         postEvents: CGPreflightPostEventAccess())
    }

    func request() {
        // The literal is kAXTrustedCheckOptionPrompt, a mutable global Swift 6 will not let us read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
    }
}

@MainActor
final class SystemInputEnvironment: InputEnvironment {
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Fails closed on any input method: marked text is invisible to us, so only a plain keyboard layout
    /// counts as non-composing.
    var isComposingInput: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return true }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return (type as String) != (kTISTypeKeyboardLayout as String)
    }
}

@MainActor
final class SystemWorkspace: WorkspaceInfo {
    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
}
