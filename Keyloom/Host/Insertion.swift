import CoreGraphics
import Foundation

enum InsertionRoute: Equatable, Sendable {
    /// Accessibility replacement of the bound range with plain text; never touches the clipboard.
    case plain
    /// Explicit user route only: styled + plain through a temporary clipboard write and one paste keystroke.
    case richPaste
}

enum ClipboardOutcome: Equatable, Sendable {
    case notTouched
    case restored
    /// Another app copied meanwhile: its clipboard was left alone.
    case restoreSkippedOwnershipLost
    /// The paste never showed up, so restoring could make a late paste insert the old clipboard: ours stays.
    case restoreSkippedPasteUnconfirmed
    case restoreFailed
}

/// Carries no text, only what happened.
enum InsertionOutcome: Equatable, Sendable {
    case replaced(mode: InsertionRoute, verified: Bool, clipboard: ClipboardOutcome)
    /// The user cancelled the prompt: the typed keyword is intact.
    case cancelled
    case failedClosed(UnsafeReason)
    case aborted(AbortReason)
    case copied

    init(_ refusal: Refusal) {
        switch refusal {
        case .failedClosed(let reason): self = .failedClosed(reason)
        case .aborted(let reason): self = .aborted(reason)
        }
    }
}

@MainActor
protocol PasteKeyPosting: AnyObject {
    /// Posts Command-V tagged with `OwnEvents.marker`. False when it could not be posted.
    func postPaste() -> Bool
}

@MainActor
final class SystemPasteKeys: PasteKeyPosting {
    private static let keyCodeV: CGKeyCode = 9

    // TODO(keyloom-mvp): key code 9 is "V" on ANSI/QWERTZ; verify on layouts that remap Command shortcuts, when the live walk covers them.
    func postPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: OwnEvents.marker)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }
}

/// Writes a rendered snippet into a bound target. Plain insertion is an Accessibility replacement verified at
/// every step; rich insertion needs the clipboard and exists only as an explicit user route. Whatever is
/// uncertain is refused and the caller offers Copy: no deletion, paste or navigation reaches an uncertain target.
@MainActor
final class InsertionEngine {
    let binder: TargetBinder
    /// Called whenever a temporary clipboard write was given back (or could not be), with what happened.
    var onClipboardOutcome: ((ClipboardOutcome) -> Void)?

    private let destination: DestinationAccess
    private let permissions: PermissionChecking
    private let pasteboard: PasteboardAccess
    private let keys: PasteKeyPosting
    private let settle: (TimeInterval) async -> Void

    init(binder: TargetBinder, destination: DestinationAccess, permissions: PermissionChecking,
         pasteboard: PasteboardAccess, keys: PasteKeyPosting, settle: @escaping (TimeInterval) async -> Void) {
        self.binder = binder
        self.destination = destination
        self.permissions = permissions
        self.pasteboard = pasteboard
        self.keys = keys
        self.settle = settle
    }

    /// `reactivating`: Keyloom's own prompt took focus, so bring the original app back before checking.
    func insert(_ rendered: RenderedSnippet, into target: BoundTarget, route: InsertionRoute, reactivating: Bool) async -> InsertionOutcome {
        switch route {
        case .plain: await insertPlain(rendered, into: target, reactivating: reactivating)
        case .richPaste: await pasteRich(rendered, into: target, reactivating: reactivating)
        }
    }

    /// Explicit user Copy: plain + styled on the clipboard, which is then the user's. Never restored.
    func copy(_ rendered: RenderedSnippet) -> InsertionOutcome {
        _ = pasteboard.write(plain: rendered.plainText, rtf: rendered.rtfData())
        return .copied
    }

    // MARK: Plain

    private func insertPlain(_ rendered: RenderedSnippet, into target: BoundTarget, reactivating: Bool) async -> InsertionOutcome {
        if let refusal = await binder.revalidate(target, reactivating: reactivating) { return .init(refusal) }
        // The last check before the mutation, and the write re-verifies the live field itself.
        guard !Task.isCancelled else { return .aborted(.cancelled) }
        switch destination.replace(range: target.range, with: rendered.plainText, bound: target.snapshot) {
        case .written: break
        case .destinationChanged:
            // The write selects before it verifies: do not leave our selection behind.
            restoreCaret(of: target)
            return .aborted(.destinationChanged)
        case .failed:
            restoreCaret(of: target)
            return .aborted(.writeFailed)
        }
        // Some apps (Electron, terminals) report success and ignore the write: read it back before counting it.
        guard destination.snapshot()?.text == Self.expectedText(after: rendered, in: target) else {
            restoreCaret(of: target)
            return .aborted(.writeUnconfirmed)
        }
        return .replaced(mode: .plain, verified: placeCaret(rendered, in: target), clipboard: .notTouched)
    }

    // MARK: Rich (explicit paste route)

    private func pasteRich(_ rendered: RenderedSnippet, into target: BoundTarget, reactivating: Bool) async -> InsertionOutcome {
        guard permissions.current().postEvents else { return .failedClosed(.richUnsupported) }
        if let refusal = await binder.revalidate(target, reactivating: reactivating) { return .init(refusal) }
        guard !Task.isCancelled else { return .aborted(.cancelled) }
        // Snapshot only now, after every await: a copy made while we waited is the user's clipboard to restore,
        // and one made since is a reason to stop. Not preservable (secret, promised or oversize) also stops here.
        let countAtSnapshot = pasteboard.changeCount
        guard let saved = pasteboard.snapshot(), pasteboard.changeCount == countAtSnapshot else {
            return .failedClosed(.richUnsupported)
        }
        var armed = target.snapshot
        if target.range.length > 0 {
            armed.selection = target.range
            guard destination.select(target.range, bound: target.snapshot) == .written,
                  destination.snapshot()?.satisfies(armed) == true
            else {
                restoreCaret(of: target)
                return .aborted(.destinationChanged)
            }
        }
        guard pasteboard.changeCount == countAtSnapshot else {
            restoreCaret(of: target)
            return .failedClosed(.richUnsupported)
        }
        let ours = pasteboard.write(plain: rendered.plainText, rtf: rendered.rtfData())
        // The last instant before the keystroke: still the same field, same selection, nothing revoked.
        if let refusal = lastInstantRefusal(armed) {
            _ = giveBack(saved, ours)
            restoreCaret(of: target)
            return .init(refusal)
        }
        guard keys.postPaste() else {
            _ = giveBack(saved, ours)
            restoreCaret(of: target)
            return .aborted(.writeFailed)
        }
        let expected = Self.expectedText(after: rendered, in: target)
        var landed = false
        for _ in 0..<TargetBinder.maxSettleAttempts {
            await settle(TargetBinder.settleInterval)
            if destination.snapshot()?.text == expected {
                landed = true
                break
            }
        }
        guard landed else {
            onClipboardOutcome?(.restoreSkippedPasteUnconfirmed)
            return .aborted(.writeUnconfirmed)
        }
        let clipboard = giveBack(saved, ours)
        return .replaced(mode: .richPaste, verified: placeCaret(rendered, in: target), clipboard: clipboard)
    }

    private func lastInstantRefusal(_ armed: FieldSnapshot) -> Refusal? {
        if Task.isCancelled { return .aborted(.cancelled) }
        if let refusal = binder.guardrails() { return refusal }
        return destination.snapshot()?.satisfies(armed) == true ? nil : .aborted(.destinationChanged)
    }

    private func giveBack(_ saved: PasteboardItems, _ ours: Int) -> ClipboardOutcome {
        let outcome: ClipboardOutcome
        switch pasteboard.restore(saved, ifChangeCount: ours) {
        case .restored: outcome = .restored
        case .ownershipLost: outcome = .restoreSkippedOwnershipLost
        case .failed: outcome = .restoreFailed
        }
        onClipboardOutcome?(outcome)
        return outcome
    }

    // MARK: Shared

    private static func expectedText(after rendered: RenderedSnippet, in target: BoundTarget) -> String {
        ((target.snapshot.text ?? "") as NSString).replacingCharacters(in: target.range, with: rendered.plainText)
    }

    /// After a successful write: caret at the cursor marker (UTF-16), then read the result back.
    private func placeCaret(_ rendered: RenderedSnippet, in target: BoundTarget) -> Bool {
        var written = target.snapshot
        written.text = ((written.text ?? "") as NSString).replacingCharacters(in: target.range, with: rendered.plainText)
        written.selection = nil
        var caret: NSRange?
        if let offset = rendered.cursorOffset {
            let wanted = NSRange(location: target.range.location + offset, length: 0)
            guard destination.select(wanted, bound: written) == .written else { return false }
            caret = wanted
        }
        let after = destination.snapshot()
        return after?.text == written.text && (caret == nil || after?.selection == caret)
    }

    /// Undoes our own keyword selection, and only while the field still selects exactly that range: a caret the
    /// user moved meanwhile is theirs. The text may have changed since (that is often why we are here), so the
    /// destination checks the selection and the field identity, not the contents.
    private func restoreCaret(of target: BoundTarget) {
        guard target.range.length > 0, let original = target.snapshot.selection else { return }
        _ = destination.restoreSelection(original, ifSelected: target.range, in: target.snapshot.token)
    }
}
