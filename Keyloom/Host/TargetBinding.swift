import Foundation

/// Why Keyloom refused to touch the destination at all.
enum UnsafeReason: String, Equatable, Sendable {
    case noFocus, appExcluded, secureField, secureInput, roleUnsupported, unreadableValue
    case selectionNotCaret, keywordNotBeforeCaret, permissionRevoked
    /// Rich insertion has no field-bound writer; Copy is the way out.
    case richUnsupported
    case snippetUnavailable, argumentsIncomplete
}

/// Why a started insertion stopped. In every case the destination text was left as it was.
enum AbortReason: String, Equatable, Sendable {
    case destinationChanged, destinationNotReactivated, writeFailed, cancelled
    /// The app took the write but the field does not read back as written (Electron and terminals can ignore
    /// Accessibility writes). The text may or may not have changed, so Copy is offered and nothing is counted as inserted.
    case writeUnconfirmed
}

enum Refusal: Error, Equatable, Sendable {
    case failedClosed(UnsafeReason)
    case aborted(AbortReason)
}

/// The field captured at trigger and the UTF-16 range that will be replaced (the typed keyword, or an empty
/// range at the caret for the picker). Every later step is checked against `snapshot`.
struct BoundTarget: Equatable, Sendable {
    let snapshot: FieldSnapshot
    let range: NSRange
}

/// Captures a destination and re-proves it is unchanged: at trigger, after any prompt and immediately before
/// replacement. Anything uncertain is a refusal, never a guess.
@MainActor
final class TargetBinder {
    /// The tap sees a key before the destination has applied it.
    static let maxSettleAttempts = 20
    static let settleInterval: TimeInterval = 0.025
    private static let supportedRoles: Set<String> = ["AXTextArea", "AXTextField"]

    private let destination: DestinationAccess
    private let environment: InputEnvironment
    private let permissions: PermissionChecking
    private let excludedBundleIDs: () -> Set<String>
    private let settle: (TimeInterval) async -> Void

    init(destination: DestinationAccess, environment: InputEnvironment, permissions: PermissionChecking,
         excludedBundleIDs: @escaping () -> Set<String>, settle: @escaping (TimeInterval) async -> Void) {
        self.destination = destination
        self.environment = environment
        self.permissions = permissions
        self.excludedBundleIDs = excludedBundleIDs
        self.settle = settle
    }

    /// Binds the keyword just typed before the caret. The tap sees a key before the app applies it, so a read
    /// taken at once can show the keyword one character early (a user's own ";" plus one typed ";" looks like
    /// ";;"), and replacing that range would delete text the user wrote. Every read therefore follows a settle,
    /// and the range is bound only once two consecutive reads agree exactly. Gives up, failing closed, after
    /// `maxSettleAttempts`.
    func bindKeyword(_ match: KeywordMatch) async -> Result<BoundTarget, Refusal> {
        var previous: BoundTarget?
        for _ in 0..<Self.maxSettleAttempts {
            await settle(Self.settleInterval)
            switch locateKeyword(match) {
            case .success(let target):
                if target == previous { return .success(target) }
                previous = target
            case .failure(.failedClosed(.keywordNotBeforeCaret)):
                previous = nil
            case .failure(let refusal):
                return .failure(refusal)
            }
        }
        return .failure(.failedClosed(.keywordNotBeforeCaret))
    }

    /// Best effort after the user cancelled Keyloom's own prompt: hand focus back to where they were typing.
    func returnFocus(to target: BoundTarget) async {
        _ = await destination.activate(target.snapshot.token)
    }

    /// Binds the caret of the focused field (picker route): an empty range, so nothing is replaced.
    func bindCaret() -> Result<BoundTarget, Refusal> {
        switch readable() {
        case .failure(let refusal): return .failure(refusal)
        case .success(let (snapshot, selection)):
            guard selection.length == 0 else { return .failure(.failedClosed(.selectionNotCaret)) }
            return .success(BoundTarget(snapshot: snapshot, range: selection))
        }
    }

    /// Nil when the destination is still exactly what was bound. `reactivating` is for after Keyloom's own
    /// prompt took focus: it brings the original app back first, and only then compares, so Keyloom's own focus
    /// transfer is never mistaken for a user change while a real change still aborts.
    func revalidate(_ target: BoundTarget, reactivating: Bool) async -> Refusal? {
        if let refusal = guardrails() ?? exclusionRefusal(target) { return refusal }
        if reactivating, await !destination.activate(target.snapshot.token) {
            return .aborted(.destinationNotReactivated)
        }
        // The user can change permissions, secure input or the exclusion list while a prompt is open.
        if let refusal = guardrails() ?? exclusionRefusal(target) { return refusal }
        guard destination.snapshot()?.satisfies(target.snapshot) == true else { return .aborted(.destinationChanged) }
        return nil
    }

    private func exclusionRefusal(_ target: BoundTarget) -> Refusal? {
        guard let bundleID = target.snapshot.bundleID, !excludedBundleIDs().contains(bundleID) else { return .failedClosed(.appExcluded) }
        return nil
    }

    /// Permissions and secure input, read now. Checked at every point of use, never cached.
    func guardrails() -> Refusal? {
        if !permissions.current().inputReady { return .failedClosed(.permissionRevoked) }
        if environment.isSecureInputActive { return .failedClosed(.secureInput) }
        return nil
    }

    private func readable() -> Result<(FieldSnapshot, NSRange), Refusal> {
        if let refusal = guardrails() { return .failure(refusal) }
        guard let snapshot = destination.snapshot() else { return .failure(.failedClosed(.noFocus)) }
        // An app that cannot be named cannot be checked against the exclusion list.
        guard let bundleID = snapshot.bundleID, !excludedBundleIDs().contains(bundleID) else {
            return .failure(.failedClosed(.appExcluded))
        }
        if snapshot.isSecure { return .failure(.failedClosed(.secureField)) }
        if !Self.supportedRoles.contains(snapshot.role) { return .failure(.failedClosed(.roleUnsupported)) }
        guard snapshot.text != nil, let selection = snapshot.selection else { return .failure(.failedClosed(.unreadableValue)) }
        return .success((snapshot, selection))
    }

    private func locateKeyword(_ match: KeywordMatch) -> Result<BoundTarget, Refusal> {
        switch readable() {
        case .failure(let refusal): return .failure(refusal)
        case .success(let (snapshot, selection)):
            guard selection.length == 0 else { return .failure(.failedClosed(.selectionNotCaret)) }
            let text = (snapshot.text ?? "") as NSString
            let length = match.typedUTF16Length
            guard length > 0, selection.location >= length, selection.location <= text.length else {
                return .failure(.failedClosed(.keywordNotBeforeCaret))
            }
            let range = NSRange(location: selection.location - length, length: length)
            // Canonical comparison: the app may hold the keyword decomposed or composed.
            guard text.substring(with: range).precomposedStringWithCanonicalMapping
                == match.keyword.precomposedStringWithCanonicalMapping
            else { return .failure(.failedClosed(.keywordNotBeforeCaret)) }
            return .success(BoundTarget(snapshot: snapshot, range: range))
        }
    }
}
