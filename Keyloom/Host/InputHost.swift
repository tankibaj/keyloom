import Foundation

/// Decides which key events reach the keyword matcher. Everything here runs inside the event-tap callback, so
/// it is bounded: a few comparisons and one `KeywordMatcher.feed` (a short lock and a loop capped at the
/// longest keyword). No database, cloud, Accessibility or model work: a match is handed to `onMatch`, which
/// must hop to an async queue.
///
/// Privacy gates run in a fixed order and BEFORE `read` is called, so a key's text is never even built while
/// input is paused, secure, composing, excluded or ours. Every dropped event also clears the matcher, so text
/// typed before and after a gap never combines into a keyword.
@MainActor
final class InputHost {
    /// Counts only; typed content is never stored.
    struct Counters: Equatable {
        var ownEventsIgnored = 0
        var syntheticIgnored = 0
        var suppressedSecure = 0
        var suppressedComposing = 0
        var suppressedExcluded = 0
        var suppressedInactive = 0
        var invalidations = 0
        var matches = 0
    }

    /// Set by the controller while the tap runs with permissions granted.
    var isEnabled = false
    var isPaused = false
    /// True while a match is being expanded: keys typed meanwhile belong to a document we are about to edit.
    var isSuspended = false
    var excludedBundleIDs: Set<String> = []
    var onMatch: ((KeywordMatch) -> Void)?

    private(set) var counters = Counters()
    private let matcher: KeywordMatcher
    private let environment: InputEnvironment
    private let workspace: WorkspaceInfo

    init(matcher: KeywordMatcher, environment: InputEnvironment, workspace: WorkspaceInfo) {
        self.matcher = matcher
        self.environment = environment
        self.workspace = workspace
    }

    func handleKeyDown(origin: InputOrigin, read: () -> KeyContent) {
        switch origin {
        case .ownProcess:
            counters.ownEventsIgnored += 1
            return
        case .synthetic:
            counters.syntheticIgnored += 1
            invalidate(counting: false)
            return
        case .physical:
            break
        }
        guard isEnabled, !isPaused, !isSuspended else { return drop(\.suppressedInactive) }
        if environment.isSecureInputActive { return drop(\.suppressedSecure) }
        if environment.isComposingInput { return drop(\.suppressedComposing) }
        guard let bundleID = workspace.frontmostBundleID, !excludedBundleIDs.contains(bundleID) else {
            return drop(\.suppressedExcluded)
        }
        let content = read()
        if content.breaksTyping { return invalidate() }
        guard let match = matcher.feed(String(decoding: content.units, as: UTF16.self)) else { return }
        counters.matches += 1
        onMatch?(match)
    }

    /// Mouse, scroll, app switch, tap restart: what was typed no longer says what is before the caret.
    func invalidate() { invalidate(counting: true) }

    private func drop(_ counter: WritableKeyPath<Counters, Int>) {
        counters[keyPath: counter] += 1
        invalidate(counting: false)
    }

    private func invalidate(counting: Bool) {
        matcher.invalidate()
        if counting { counters.invalidations += 1 }
    }
}
