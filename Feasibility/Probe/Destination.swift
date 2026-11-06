import AppKit
import ApplicationServices

/// Accessibility-backed access to the focused text field of another app.
/// Every call re-reads the live focus; nothing is cached beyond element identity.
/// Writes act on the element they just verified, never on whatever is focused later.
final class AXDestination: DestinationAccess {
    static let allowedBundleIDs: Set<String> = [
        "com.apple.TextEdit", "com.apple.Safari", "com.microsoft.VSCode",
    ]

    private typealias Focus = (element: AXUIElement, token: FocusToken)

    private var lastElement: AXUIElement?
    private var lastID = 0

    private func focused() -> Focus? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        if lastElement == nil || !CFEqual(lastElement, element) {
            lastID += 1
            lastElement = element
        }
        return (element, FocusToken(pid: pid, element: lastID))
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func selectionRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func snapshot(of focus: Focus) -> FieldSnapshot {
        FieldSnapshot(
            token: focus.token,
            bundleID: NSRunningApplication(processIdentifier: focus.token.pid)?.bundleIdentifier,
            role: attribute(focus.element, kAXRoleAttribute) as? String ?? "",
            isSecure: (attribute(focus.element, kAXSubroleAttribute) as? String) == "AXSecureTextField",
            text: attribute(focus.element, kAXValueAttribute) as? String,
            selection: selectionRange(focus.element)
        )
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

    /// Selects `range` on the verified element and confirms the app took it, so the
    /// write that follows replaces exactly that range of exactly that value.
    private func selectVerified(_ range: NSRange, bound: FieldSnapshot) -> (result: WriteResult, focus: Focus?) {
        guard let focus = verified(bound) else { return (.destinationChanged, nil) }
        guard setSelection(range, on: focus.element) else { return (.failed, nil) }
        var selected = bound
        selected.selection = range
        guard let again = verified(selected) else { return (.destinationChanged, nil) }
        return (.written, again)
    }

    func focusToken() -> FocusToken? { focused()?.token }

    func snapshot() -> FieldSnapshot? { focused().map(snapshot(of:)) }

    func activate(_ token: FocusToken) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: token.pid) else { return false }
        NSApp.yieldActivation(to: app)
        guard app.activate() else { return false }
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while Date() < deadline {
            if focusToken() == token { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return false
    }

    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult {
        guard let focus = verified(bound) else { return .destinationChanged }
        return setSelection(range, on: focus.element) ? .written : .failed
    }

    func replace(range: NSRange, with text: String, bound: FieldSnapshot) -> WriteResult {
        let selected = selectVerified(range, bound: bound)
        guard let focus = selected.focus else { return selected.result }
        return AXUIElementSetAttributeValue(
            focus.element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success ? .written : .failed
    }
}
