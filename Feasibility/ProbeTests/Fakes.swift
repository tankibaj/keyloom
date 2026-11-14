import Foundation

// Fakes for the OS boundaries only (focused field, pasteboard, input
// environment). Passing tests against them prove the engine's decisions, not
// real destination behavior.

/// Plain-text destination: like the real Accessibility one, it has no field-bound rich writer.
class FakeDestination: DestinationAccess {
    var token: FocusToken? = FocusToken(pid: 100, element: 1)
    var bundleID = "com.apple.TextEdit"
    var role = "AXTextArea"
    var isSecure = false
    var text: String?
    var selection: NSRange?
    var canActivate = true
    private(set) var activateCount = 0
    /// The world changing under the engine: runs right before a write reaches the field.
    var beforeWrite: (() -> Void)?
    /// Runs on every full read, before it is taken.
    var onSnapshot: (() -> Void)?
    /// Every mutation the engine asked for; empty means the destination was left alone.
    private(set) var writes: [String] = []

    init(prefix: String, typed: String, suffix: String) {
        text = prefix + typed + suffix
        selection = NSRange(location: (prefix + typed).utf16.count, length: 0)
    }

    func focusToken() -> FocusToken? { token }

    func snapshot() -> FieldSnapshot? {
        onSnapshot?()
        return liveSnapshot()
    }

    private func liveSnapshot() -> FieldSnapshot? {
        guard let token else { return nil }
        return FieldSnapshot(
            token: token, bundleID: bundleID, role: role, isSecure: isSecure, text: text, selection: selection
        )
    }

    /// The contract every write honors: nothing happens unless the live field still satisfies `bound`.
    final func accepts(_ bound: FieldSnapshot) -> Bool {
        beforeWrite?()
        return liveSnapshot()?.satisfies(bound) == true
    }

    func activate(_ token: FocusToken) -> Bool {
        activateCount += 1
        return canActivate
    }

    func replace(range: NSRange, with replacement: String, bound: FieldSnapshot) -> WriteResult {
        guard accepts(bound) else { return .destinationChanged }
        record("replace")
        splice(range, replacement)
        return .written
    }

    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult {
        guard accepts(bound) else { return .destinationChanged }
        record("select")
        selection = range
        return .written
    }

    final func record(_ write: String) { writes.append(write) }

    final func splice(_ range: NSRange, _ replacement: String) {
        text = ((text ?? "") as NSString).replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
    }
}

/// A destination that can write styled text into the bound field itself.
final class FakeRichDestination: FakeDestination, RichFieldWriter {
    private(set) var lastSnippet: RenderedSnippet?

    func replaceRich(range: NSRange, with snippet: RenderedSnippet, bound: FieldSnapshot) -> WriteResult {
        guard accepts(bound) else { return .destinationChanged }
        record("replaceRich")
        lastSnippet = snippet
        splice(range, snippet.text)
        return .written
    }
}

final class FakePasteboard: PasteboardAccess {
    private(set) var plain: String?
    private(set) var lastRTF: Data?
    private(set) var writeCount = 0

    init(userClipboard: String? = nil) {
        plain = userClipboard
    }

    func write(plain: String, rtf: Data?) {
        writeCount += 1
        self.plain = plain
        lastRTF = rtf
    }
}

final class FakeEnvironment: InputEnvironment {
    var isSecureInputActive = false
    var isComposingInput = false
    var onWait: (() -> Void)?

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        onWait?()
        return condition()
    }
}
