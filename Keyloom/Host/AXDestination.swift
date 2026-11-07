import AppKit
import ApplicationServices

/// Accessibility-backed access to the focused text field of another app. Not unit-testable (it needs a live
/// app and the Accessibility grant); `TargetBindingTests` and `InsertionTests` cover the decisions around it
/// with fakes that honor the same `DestinationAccess` contract, and the live walk covers this file.
///
/// Every call re-reads the live focus. A write verifies the live field against `bound`, selects the target
/// range on THAT element, verifies the app took the selection, and only then writes the selected text, so a
/// failure at any step leaves the document untouched (a leftover selection changes nothing).
@MainActor
final class AXDestination: DestinationAccess {
    private typealias Focus = (element: AXUIElement, token: FocusToken)

    private var identities = ElementIdentityCache<AXUIElement>(capacity: 16, same: { CFEqual($0, $1) })

    init() {
        // A hung target app must not freeze Keyloom for the 6 s default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    private func focused() -> Focus? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return (element, FocusToken(pid: pid, element: identities.id(for: element)))
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func selectionRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func snapshot(of focus: Focus) -> FieldSnapshot {
        FieldSnapshot(
            token: focus.token,
            bundleID: NSRunningApplication(processIdentifier: focus.token.pid)?.bundleIdentifier,
            role: attribute(focus.element, kAXRoleAttribute) as? String ?? "",
            isSecure: (attribute(focus.element, kAXSubroleAttribute) as? String) == "AXSecureTextField",
            text: attribute(focus.element, kAXValueAttribute) as? String,
            selection: selectionRange(focus.element))
    }

    /// The focused field, only while it still is exactly what `bound` captured.
    private func verified(_ bound: FieldSnapshot) -> Focus? {
        guard let focus = focused(), snapshot(of: focus).satisfies(bound) else { return nil }
        return focus
    }

    private func setSelection(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func focusToken() -> FocusToken? { focused()?.token }

    func snapshot() -> FieldSnapshot? { focused().map(snapshot(of:)) }

    func activate(_ token: FocusToken) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: token.pid) else { return false }
        NSApp.yieldActivation(to: app)
        guard app.activate() else { return false }
        for _ in 0..<50 {
            if focusToken() == token { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult {
        guard let focus = verified(bound) else { return .destinationChanged }
        return setSelection(range, on: focus.element) ? .written : .failed
    }

    func replace(range: NSRange, with text: String, bound: FieldSnapshot) -> WriteResult {
        guard let focus = verified(bound) else { return .destinationChanged }
        guard setSelection(range, on: focus.element) else { return .failed }
        var selected = bound
        selected.selection = range
        // Re-read after our own selection change: the app must hold exactly that selection of exactly that value.
        guard let again = verified(selected) else { return .destinationChanged }
        return AXUIElementSetAttributeValue(again.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            ? .written : .failed
    }
}
