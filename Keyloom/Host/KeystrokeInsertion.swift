import Foundation

/// Replaces a typed keyword by typing over it: Delete for each character, then a paste of the snippet. For the
/// fields Accessibility cannot read or write (browsers, Electron apps, terminals), which is most apps outside
/// the native Cocoa ones.
///
/// Nothing can be read back here, so it is bounded instead of verified. It runs only when nothing was typed,
/// clicked or switched since the match, in the same frontmost app, never under secure input and never in an
/// excluded app. The clipboard is borrowed for one paste and given back only while it is still ours.
@MainActor
final class KeystrokeInserter {
    /// How long the destination gets to take the paste before the clipboard is restored. Restoring too early
    /// would let a slow app paste the old clipboard instead. NOT VERIFIED against slow apps.
    static let pasteSettle: TimeInterval = 0.25
    /// An Accessibility write that failed or was ignored is only typed over once the field read back unchanged this
    /// many times in a row, this far apart: a slow app that applies the write late would otherwise get the snippet
    /// twice. NOT VERIFIED against slow apps.
    static let unchangedReads = 2
    static let lateWriteSettle: TimeInterval = 0.05
    /// Apps where Delete and paste act on files, not text, so a keyword is never typed over blindly.
    private static let neverTypedOverApps: Set<String> = ["com.apple.finder"]
    /// Roles that are never typed over: Delete in a list, table or menu could remove an item instead of a character.
    /// Every other role is allowed, because apps report their editors under many roles (web areas, groups, custom views).
    private static let neverTypedOver: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXColumn", "AXBrowser", "AXButton", "AXMenu", "AXMenuItem",
        "AXMenuBar", "AXMenuBarItem", "AXPopUpButton", "AXTabGroup", "AXToolbar", "AXScrollBar", "AXSlider", "AXCheckBox",
        "AXRadioButton", "AXImage", "AXCollection",
    ]

    /// Called whenever the temporary clipboard write was given back (or could not be), as for `InsertionEngine`.
    var onClipboardOutcome: ((ClipboardOutcome) -> Void)?

    /// The user's switch for expanding in apps Accessibility cannot inspect.
    var isEnabled = true

    private let destination: DestinationAccess
    private let environment: InputEnvironment
    private let workspace: WorkspaceInfo
    private let permissions: PermissionChecking
    private let pasteboard: PasteboardAccess
    private let keys: PasteKeyPosting
    private let excludedBundleIDs: () -> Set<String>
    private let settle: (TimeInterval) async -> Void

    init(destination: DestinationAccess, environment: InputEnvironment, workspace: WorkspaceInfo, permissions: PermissionChecking,
         pasteboard: PasteboardAccess, keys: PasteKeyPosting, excludedBundleIDs: @escaping () -> Set<String>,
         settle: @escaping (TimeInterval) async -> Void) {
        self.destination = destination
        self.environment = environment
        self.workspace = workspace
        self.permissions = permissions
        self.pasteboard = pasteboard
        self.keys = keys
        self.excludedBundleIDs = excludedBundleIDs
        self.settle = settle
    }

    /// Whether a refused bind is one this route may take over: a field Accessibility cannot see or read.
    func accepts(_ reason: UnsafeReason) -> Bool {
        guard allowedHere else { return false }
        return switch reason {
        case .noFocus, .unreadableValue: true
        case .roleUnsupported: destination.snapshot().map { !Self.neverTypedOver.contains($0.role) } ?? false
        default: false
        }
    }

    /// Whether an Accessibility write that failed or was ignored left the field exactly as it was bound.
    func accepts(afterFailedWriteTo target: BoundTarget) async -> Bool {
        guard allowedHere else { return false }
        for _ in 0..<Self.unchangedReads {
            await settle(Self.lateWriteSettle)
            guard destination.snapshot()?.satisfies(target.snapshot) == true else { return false }
        }
        return true
    }

    private var allowedHere: Bool {
        isEnabled && workspace.frontmostBundleID.map { !Self.neverTypedOverApps.contains($0) } ?? false
    }

    /// `interrupted` says whether anything was typed, clicked or switched since the match.
    func insert(_ rendered: RenderedSnippet, replacing match: KeywordMatch, interrupted: () -> Bool) async -> InsertionOutcome {
        if let refusal = refusal() { return .init(refusal) }
        guard let bundleID = workspace.frontmostBundleID, let pid = workspace.frontmostPID,
              !excludedBundleIDs().contains(bundleID)
        else { return .failedClosed(.appExcluded) }
        let countAtSnapshot = pasteboard.changeCount
        guard let saved = pasteboard.snapshot(), pasteboard.changeCount == countAtSnapshot else {
            return .failedClosed(.richUnsupported)
        }
        let styled = rendered.segments.contains { !$0.style.isEmpty }
        let ours = pasteboard.write(plain: rendered.plainText, rtf: styled ? rendered.rtfData() : nil, transient: true)
        // The last instant before the first keystroke.
        if Task.isCancelled || interrupted() || workspace.frontmostPID != pid || workspace.frontmostBundleID != bundleID {
            _ = giveBack(saved, ours)
            return .aborted(Task.isCancelled ? .cancelled : .destinationChanged)
        }
        if let refusal = refusal() {
            _ = giveBack(saved, ours)
            return .init(refusal)
        }
        guard keys.postDeletesThenPaste(deleting: match.keyword.count, toPid: pid) else {
            _ = giveBack(saved, ours)
            return .aborted(.writeFailed)
        }
        await settle(Self.pasteSettle)
        let clipboard = giveBack(saved, ours)
        // The user may have typed or switched apps while the paste settled; the caret is then theirs.
        if let offset = rendered.cursorOffset, !interrupted(), workspace.frontmostPID == pid, refusal() == nil {
            let after = String(rendered.plainText.utf16.dropFirst(offset)) ?? ""
            _ = keys.postLeftArrows(after.count, toPid: pid)
        }
        return .replaced(mode: .plain, verified: false, clipboard: clipboard)
    }

    private func refusal() -> Refusal? {
        if !permissions.current().inputReady { return .failedClosed(.permissionRevoked) }
        if environment.isSecureInputActive { return .failedClosed(.secureInput) }
        return nil
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
}
