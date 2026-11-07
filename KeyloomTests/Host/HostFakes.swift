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

/// Plain-text field. Like the real Accessibility destination, every write honors its contract: nothing happens
/// unless the live field still satisfies `bound`.
@MainActor
class FakeDestination: DestinationAccess {
    var token: FocusToken? = FocusToken(pid: 100, element: 1)
    var bundleID = "com.apple.TextEdit"
    var role = "AXTextArea"
    var isSecure = false
    var text: String?
    var selection: NSRange?
    var canActivate = true
    var onActivate: ((FocusToken) -> Void)?
    private(set) var activateCount = 0
    /// The world changing under the host: runs right before a write reaches the field.
    var beforeWrite: (() -> Void)?
    /// Every mutation asked for; empty means the destination was left alone.
    private(set) var writes: [String] = []

    init(prefix: String, typed: String, suffix: String) {
        text = prefix + typed + suffix
        selection = NSRange(location: (prefix + typed).utf16.count, length: 0)
    }

    func focusToken() -> FocusToken? { token }

    func snapshot() -> FieldSnapshot? {
        guard let token else { return nil }
        return FieldSnapshot(token: token, bundleID: bundleID, role: role, isSecure: isSecure, text: text, selection: selection)
    }

    func activate(_ token: FocusToken) async -> Bool {
        activateCount += 1
        onActivate?(token)
        return canActivate
    }

    func replace(range: NSRange, with replacement: String, bound: FieldSnapshot) -> WriteResult {
        guard accepts(bound) else { return .destinationChanged }
        writes.append("replace")
        splice(range, replacement)
        return .written
    }

    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult {
        guard accepts(bound) else { return .destinationChanged }
        writes.append("select")
        selection = range
        return .written
    }

    final func accepts(_ bound: FieldSnapshot) -> Bool {
        beforeWrite?()
        return snapshot()?.satisfies(bound) == true
    }

    final func splice(_ range: NSRange, _ replacement: String) {
        text = ((text ?? "") as NSString).replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
    }
}

/// Records whether a lazily-read value was ever read.
final class ReadFlag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}

/// In-memory pasteboard with a change count that moves on every write, like NSPasteboard's.
@MainActor
final class FakePasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private(set) var items: PasteboardItems = []
    private(set) var writeCount = 0
    var isPreservable = true
    /// Runs right after our write, before anything else can happen.
    var onWrite: (() -> Void)?

    init(userClipboard: String? = nil) {
        if let userClipboard { items = [["public.utf8-plain-text": Data(userClipboard.utf8)]] }
    }

    var plain: String? { plainText() }

    func plainText() -> String? { items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
    func snapshot() -> PasteboardItems? { isPreservable ? items : nil }

    func write(plain: String, rtf: Data?) -> Int {
        writeCount += 1
        items = [["public.utf8-plain-text": Data(plain.utf8)].merging(rtf.map { ["public.rtf": $0] } ?? [:]) { $1 }]
        changeCount += 1
        onWrite?()
        return changeCount
    }

    func restore(_ restored: PasteboardItems, ifChangeCount expected: Int) -> PasteboardRestore {
        guard changeCount == expected else { return .ownershipLost }
        items = restored
        changeCount += 1
        return .restored
    }

    /// Another app copying something.
    func otherAppCopies(_ text: String) {
        items = [["public.utf8-plain-text": Data(text.utf8)]]
        changeCount += 1
    }
}

@MainActor
final class FakePasteKeys: PasteKeyPosting {
    private(set) var postCount = 0
    var succeeds = true
    var onPost: (() -> Void)?

    func postPaste() -> Bool {
        postCount += 1
        onPost?()
        return succeeds
    }
}
