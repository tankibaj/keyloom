import Foundation

// WP1 probe engine: pure decision logic. Every OS boundary (focused field,
// pasteboard, input environment) is a protocol so the fail-closed rules are
// testable without a real destination. A passing engine test is not
// destination evidence; that comes only from the live runs.

struct FocusToken: Equatable {
    let pid: Int32
    let element: Int
}

struct FieldSnapshot: Equatable {
    var token: FocusToken
    var bundleID: String?
    var role: String
    var isSecure: Bool
    var text: String?
    var selection: NSRange?
}

enum InputOrigin: Equatable {
    /// No originating process: presumed hardware keyboard.
    case physical
    /// Posted by another process (automation). Never counts as physical evidence.
    case synthetic
    /// Posted by the probe's own process; always filtered.
    case ownProcess
}

struct KeyInput: Equatable {
    var units: [UInt16]
    var keyCode: UInt16
    /// Command, control or option held: a shortcut, not typing.
    var isShortcut: Bool
    var origin: InputOrigin

    static func typed(_ unit: UInt16, origin: InputOrigin = .physical) -> KeyInput {
        KeyInput(units: [unit], keyCode: 0, isShortcut: false, origin: origin)
    }
}

extension FieldSnapshot {
    /// Same element, app and exact value as `bound`. A nil bound selection leaves
    /// the caret free (used once our own write has moved it).
    func satisfies(_ bound: FieldSnapshot) -> Bool {
        token == bound.token && bundleID == bound.bundleID && role == bound.role
            && isSecure == bound.isSecure && text == bound.text
            && (bound.selection == nil || selection == bound.selection)
    }
}

enum WriteResult: Equatable {
    case written, destinationChanged, failed
}

protocol DestinationAccess: AnyObject {
    /// Cheap identity of the focused field; nil when nothing usable has focus.
    func focusToken() -> FocusToken?
    /// Full state of the focused field; nil when it cannot be read.
    func snapshot() -> FieldSnapshot?
    /// Brings the field's application back to the front. True once it is focused again.
    func activate(_ token: FocusToken) -> Bool
    /// Every write below re-reads the live field right before touching it and
    /// returns `.destinationChanged`, having written nothing, unless it still satisfies `bound`.
    func replace(range: NSRange, with text: String, bound: FieldSnapshot) -> WriteResult
    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult
}

/// A destination that can write styled text into the bound field itself, with the
/// same bound check as `replace` and no keystroke or clipboard. Accessibility offers
/// no such writer (a synthetic paste cannot be bound to one field), so the real
/// destination does not conform and rich insertion fails closed.
protocol RichFieldWriter: DestinationAccess {
    func replaceRich(range: NSRange, with snippet: RenderedSnippet, bound: FieldSnapshot) -> WriteResult
}

protocol PasteboardAccess: AnyObject {
    /// Explicit user Copy only; the probe never writes the clipboard on its own.
    func write(plain: String, rtf: Data?)
}

protocol InputEnvironment: AnyObject {
    var isSecureInputActive: Bool { get }
    /// An input method (not a plain layout) is active: composition cannot be ruled out.
    var isComposingInput: Bool { get }
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool
}

enum UnsafeReason: String, Error, Equatable {
    case noFocus, appNotAllowed, secureField, secureInput, roleUnsupported
    case unreadableValue, notFixtureDocument, selectionNotCaret, keywordNotBeforeCaret
    /// Rich mode without a field-bound styled writer; Copy is the way out.
    case richUnsupported
}

enum AbortReason: String, Equatable {
    case destinationChanged, destinationNotReactivated, writeFailed
}

enum DeliveryMode: String, CaseIterable {
    case axPlain = "AX plain"
    case richField = "Rich (field-bound writer)"
}

/// Delivery never touches the clipboard; only an explicit Copy does.
enum ClipboardOutcome: String, Equatable {
    case notTouched
}

enum Outcome: Equatable {
    case replaced(mode: DeliveryMode, verified: Bool, clipboard: ClipboardOutcome)
    case cancelled
    case failedClosed(UnsafeReason)
    case aborted(AbortReason)
    case copied
}

/// Counts only; typed content is never stored.
struct Counters: Equatable {
    var physical = 0
    var synthetic = 0
    var syntheticIgnored = 0
    var ownProcessFiltered = 0
    var suppressedSecure = 0
    var suppressedComposing = 0
    var invalidations = 0
    var matches = 0
}

struct PendingInsertion: Equatable {
    let match: KeywordMatch
    let snapshot: FieldSnapshot
    let keywordRange: NSRange
}

final class ProbeEngine {
    /// Only text fields containing this marker are ever read or fed to the matcher.
    static let sentinel = "KL-FIXTURE-v1"
    static let supportedRoles: Set<String> = ["AXTextArea", "AXTextField"]
    private static let navigationKeyCodes: Set<UInt16> = [
        36, 48, 51, 53, 71, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    var armed = false {
        didSet { if !armed { clearTransientState() } }
    }
    var acceptSynthetic = false
    var deliveryMode: DeliveryMode = .axPlain
    var allowedBundleIDs: Set<String>
    var onPrompt: ((PendingInsertion) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    private(set) var counters = Counters()
    private(set) var pending: PendingInsertion?
    private(set) var lastOutcome: Outcome?

    let recognizer = Recognizer()
    private let destination: DestinationAccess
    private let pasteboard: PasteboardAccess
    private let environment: InputEnvironment
    private var lastToken: FocusToken?
    private var lastEligibility: UnsafeReason?
    private var lastFixtureIndex: Int?
    private var isProcessing = false

    init(
        destination: DestinationAccess,
        pasteboard: PasteboardAccess,
        environment: InputEnvironment,
        allowedBundleIDs: Set<String>
    ) {
        self.destination = destination
        self.pasteboard = pasteboard
        self.environment = environment
        self.allowedBundleIDs = allowedBundleIDs
    }

    // MARK: Input

    func handle(_ event: TapEvent) {
        switch event {
        case .key(let input): handleKey(input)
        case .secureKeySuppressed: noteSecureKeySuppressed()
        case .navigation: noteNavigation()
        }
    }

    func handleKey(_ input: KeyInput) {
        guard armed, pending == nil, !isProcessing else { return }
        switch input.origin {
        case .ownProcess:
            counters.ownProcessFiltered += 1
            return
        case .synthetic:
            guard acceptSynthetic else {
                counters.syntheticIgnored += 1
                return
            }
            counters.synthetic += 1
        case .physical:
            counters.physical += 1
        }
        if environment.isSecureInputActive {
            counters.suppressedSecure += 1
            invalidate()
            return
        }
        if environment.isComposingInput {
            counters.suppressedComposing += 1
            invalidate()
            return
        }
        if Self.breaksTyping(input) {
            invalidate()
            return
        }
        guard let token = destination.focusToken() else {
            lastToken = nil
            invalidate()
            return
        }
        if token != lastToken {
            recognizer.reset()
            lastToken = token
            lastEligibility = eligibility(of: destination.snapshot())
        }
        // Text outside an eligible fixture field never reaches the matcher.
        guard lastEligibility == nil else { return }
        guard let match = recognizer.push(input.units) else { return }
        counters.matches += 1
        begin(match)
    }

    /// Mouse, scroll or other navigation that invalidates what was typed.
    func noteNavigation() {
        guard armed else { return }
        invalidate()
    }

    /// The tap dropped a secure keyboard event unread. Its content is unknown, so
    /// what was typed before it must not combine with what is typed after it.
    func noteSecureKeySuppressed() {
        guard armed else { return }
        counters.suppressedSecure += 1
        invalidate()
    }

    private static func breaksTyping(_ input: KeyInput) -> Bool {
        if input.isShortcut || input.units.isEmpty || navigationKeyCodes.contains(input.keyCode) {
            return true
        }
        return input.units.contains { $0 < 0x20 || $0 == 0x7F || (0xF700...0xF8FF).contains($0) }
    }

    private func invalidate() {
        recognizer.reset()
        counters.invalidations += 1
    }

    private func clearTransientState() {
        recognizer.reset()
        lastToken = nil
        lastEligibility = nil
        pending = nil
    }

    // MARK: Trigger

    private func eligibility(of snapshot: FieldSnapshot?) -> UnsafeReason? {
        guard let snapshot else { return .noFocus }
        guard let bundleID = snapshot.bundleID, allowedBundleIDs.contains(bundleID) else {
            return .appNotAllowed
        }
        if snapshot.isSecure { return .secureField }
        if !Self.supportedRoles.contains(snapshot.role) { return .roleUnsupported }
        guard let text = snapshot.text else { return .unreadableValue }
        if !text.contains(Self.sentinel) { return .notFixtureDocument }
        return nil
    }

    private func locateKeyword(_ match: KeywordMatch) -> Result<PendingInsertion, UnsafeReason> {
        let snapshot = destination.snapshot()
        if let reason = eligibility(of: snapshot) { return .failure(reason) }
        guard let snapshot, let text = snapshot.text, let selection = snapshot.selection else {
            return .failure(.unreadableValue)
        }
        guard selection.length == 0 else { return .failure(.selectionNotCaret) }
        let ns = text as NSString
        guard selection.location >= match.keywordLength, selection.location <= ns.length,
              let keyword = Recognizer.keyword(fixtureIndex: match.fixtureIndex)
        else { return .failure(.keywordNotBeforeCaret) }
        let range = NSRange(location: selection.location - match.keywordLength, length: match.keywordLength)
        guard ns.substring(with: range).precomposedStringWithCanonicalMapping
            == keyword.precomposedStringWithCanonicalMapping
        else { return .failure(.keywordNotBeforeCaret) }
        return .success(PendingInsertion(match: match, snapshot: snapshot, keywordRange: range))
    }

    private func begin(_ match: KeywordMatch) {
        isProcessing = true
        defer { isProcessing = false }
        lastFixtureIndex = match.fixtureIndex
        var located = locateKeyword(match)
        // The tap sees a key before the destination has applied it; wait for the
        // keyword to appear before judging it.
        if case .failure(.keywordNotBeforeCaret) = located {
            _ = environment.waitUntil(timeout: 0.5) {
                located = locateKeyword(match)
                if case .failure(.keywordNotBeforeCaret) = located { return false }
                return true
            }
        }
        switch located {
        case .failure(let reason):
            finish(.failedClosed(reason))
        case .success(let insertion) where match.hasArgument:
            pending = insertion
            onPrompt?(insertion)
        case .success(let insertion):
            deliver(insertion, argument: nil)
        }
    }

    // MARK: Prompt resolution (user actions)

    func cancel() {
        guard pending != nil else { return }
        pending = nil
        finish(.cancelled)
    }

    func confirm(argument: String?) {
        guard let insertion = pending else { return }
        pending = nil
        guard canInsert else {
            finish(.failedClosed(.richUnsupported))
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        guard destination.activate(insertion.snapshot.token) else {
            finish(.aborted(.destinationNotReactivated))
            return
        }
        if environment.isSecureInputActive {
            finish(.failedClosed(.secureInput))
            return
        }
        guard destination.snapshot() == insertion.snapshot else {
            finish(.aborted(.destinationChanged))
            return
        }
        deliver(insertion, argument: argument)
    }

    /// User-initiated only: the probe writes the clipboard nowhere else. Plain text
    /// plus the styled (RTF) form, rendered with the given argument.
    func copyFallback(argument: String?) {
        guard let index = lastFixtureIndex,
              let rendered = Recognizer.render(fixtureIndex: index, argument: argument)
        else { return }
        pending = nil
        pasteboard.write(plain: rendered.text, rtf: rendered.rtfData())
        finish(.copied)
    }

    // MARK: Delivery

    /// False when the chosen mode has no safe writer for the current destination.
    /// Checked before any activation, selection, clipboard or field write.
    var canInsert: Bool { deliveryMode == .axPlain || destination is RichFieldWriter }

    private func deliver(_ insertion: PendingInsertion, argument: String?) {
        guard let rendered = Recognizer.render(fixtureIndex: insertion.match.fixtureIndex, argument: argument)
        else {
            finish(.aborted(.writeFailed))
            return
        }
        let written: WriteResult
        switch deliveryMode {
        case .axPlain:
            written = destination.replace(range: insertion.keywordRange, with: rendered.text, bound: insertion.snapshot)
        case .richField:
            guard let writer = destination as? RichFieldWriter else {
                finish(.failedClosed(.richUnsupported))
                return
            }
            written = writer.replaceRich(range: insertion.keywordRange, with: rendered, bound: insertion.snapshot)
        }
        guard written == .written else {
            finish(.aborted(written == .destinationChanged ? .destinationChanged : .writeFailed))
            return
        }
        finishReplaced(deliveryMode, insertion, rendered)
    }

    /// Same field with the replacement applied; the caret is whatever the app left.
    private func replacedSnapshot(_ insertion: PendingInsertion, _ rendered: RenderedSnippet) -> FieldSnapshot {
        var replaced = insertion.snapshot
        replaced.text = ((replaced.text ?? "") as NSString).replacingCharacters(in: insertion.keywordRange, with: rendered.text)
        replaced.selection = nil
        return replaced
    }

    /// Places the caret (only in the field we just wrote) and reads the result back.
    private func finishReplaced(_ mode: DeliveryMode, _ insertion: PendingInsertion, _ rendered: RenderedSnippet) {
        let replaced = replacedSnapshot(insertion, rendered)
        let caret = NSRange(location: insertion.keywordRange.location + rendered.cursor, length: 0)
        let caretSet = destination.select(caret, bound: replaced) == .written
        let after = destination.snapshot()
        finish(.replaced(
            mode: mode,
            verified: caretSet && after?.text == replaced.text && after?.selection == caret,
            clipboard: .notTouched
        ))
    }

    private func finish(_ outcome: Outcome) {
        lastOutcome = outcome
        onOutcome?(outcome)
    }
}
