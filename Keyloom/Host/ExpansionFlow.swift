import Foundation

/// Implemented by the UI. Shows the argument prompt and returns the answers by argument name, or nil when the
/// user cancels. The prompt never touches the destination, and must return nil promptly when its task is
/// cancelled (the host cancels on pause, stop and permission loss). Return focus to the original app on
/// cancel; on confirm the host reactivates it itself and aborts if the field changed meanwhile.
@MainActor
protocol ArgumentPrompting: AnyObject {
    func promptForArguments(for snippetID: UUID, requirements: [ArgumentRequirement]) async -> [String: String]?
}

struct ExpansionResult: Equatable, Sendable {
    var outcome: InsertionOutcome
    /// Set when the destination was left alone but Copy can still deliver the text. Never copied on its own.
    var copyOffer: RenderedSnippet?
}

extension InsertionOutcome {
    /// Refusals about privacy or permissions never render the snippet, so there is nothing to offer.
    var allowsCopyOffer: Bool {
        switch self {
        case .failedClosed(let reason):
            [.roleUnsupported, .unreadableValue, .selectionNotCaret, .keywordNotBeforeCaret, .richUnsupported].contains(reason)
        case .aborted(let reason):
            reason != .cancelled
        case .replaced, .cancelled, .copied:
            false
        }
    }
}

/// Match -> bind -> expand -> prompt -> revalidate -> write. Runs off the event-tap callback, one match at a time.
@MainActor
final class ExpansionCoordinator {
    private let library: SnippetLibrary
    private let binder: TargetBinder
    private let engine: InsertionEngine
    private let prompter: ArgumentPrompting
    private let environment: @MainActor () -> RenderEnvironment
    /// Types over keywords in fields Accessibility cannot drive. Nil leaves those refused with Copy offered.
    private let keystrokes: KeystrokeInserter?
    /// Called when a usage write fails, after an insertion that already succeeded.
    var onUsageRecordFailed: (@MainActor () -> Void)?
    /// Usage writes run one after another off the resume path; each waits for the one before it.
    private var usageRecording: Task<Void, Never>?

    init(library: SnippetLibrary, binder: TargetBinder, engine: InsertionEngine, prompter: ArgumentPrompting,
         keystrokes: KeystrokeInserter? = nil, environment: @escaping @MainActor () -> RenderEnvironment) {
        self.library = library
        self.binder = binder
        self.engine = engine
        self.prompter = prompter
        self.keystrokes = keystrokes
        self.environment = environment
    }

    /// `interrupted` says whether anything was typed, clicked or switched since the match; the keystroke route
    /// cannot read the field, so it gives up when that is true.
    func handle(_ match: KeywordMatch, interrupted: @MainActor () -> Bool = { false }) async -> ExpansionResult {
        let target: BoundTarget
        switch await binder.bindKeyword(match) {
        case .success(let bound): target = bound
        case .failure(let refusal):
            if case .failedClosed(let reason) = refusal, keystrokes?.accepts(reason) == true {
                return await typeOver(match, refused: refusal, interrupted: interrupted)
            }
            let outcome = InsertionOutcome(refusal)
            return ExpansionResult(outcome: outcome, copyOffer: outcome.allowsCopyOffer ? await renderWithoutPrompt(match) : nil)
        }
        var prompted = false
        let rendered: RenderedSnippet
        do {
            var expansion = try await library.expansion(for: match, environment: environment())
            if case .needsArguments(let requirements) = expansion {
                prompted = true
                guard let answers = await prompter.promptForArguments(for: match.snippetID, requirements: requirements) else {
                    await binder.returnFocus(to: target)
                    return ExpansionResult(outcome: .cancelled)
                }
                expansion = try await library.expansion(for: match, arguments: answers, environment: environment())
            }
            guard case .rendered(let result) = expansion else { return ExpansionResult(outcome: .failedClosed(.argumentsIncomplete)) }
            rendered = result
        } catch let error as StoreError where error == .notFound(id: match.snippetID) {
            return ExpansionResult(outcome: .failedClosed(.snippetUnavailable))
        } catch {
            return ExpansionResult(outcome: .failedClosed(.argumentsIncomplete))
        }
        var outcome = await engine.insert(rendered, into: target, route: .plain, reactivating: prompted)
        // An app that refused or ignored the write left the field as bound; typing over the keyword may still work.
        // After a prompt the app was switched away and back, which the interruption check cannot tell from the user's.
        if !prompted, let keystrokes, case .aborted(let reason) = outcome, reason == .writeFailed || reason == .writeUnconfirmed,
           await keystrokes.accepts(afterFailedWriteTo: target) {
            outcome = await keystrokes.insert(rendered, replacing: match, interrupted: interrupted)
        }
        return await finish(outcome, rendered: rendered, snippetID: match.snippetID)
    }

    /// A field Accessibility cannot see: no prompt (the field cannot be checked after one), so a snippet that
    /// needs answers stays refused.
    private func typeOver(_ match: KeywordMatch, refused: Refusal, interrupted: @MainActor () -> Bool) async -> ExpansionResult {
        guard let keystrokes, let rendered = await renderWithoutPrompt(match) else {
            return ExpansionResult(outcome: InsertionOutcome(refused))
        }
        let outcome = await keystrokes.insert(rendered, replacing: match, interrupted: interrupted)
        return await finish(outcome, rendered: rendered, snippetID: match.snippetID)
    }

    /// Shared with the picker route: usage is recorded only once text is actually inserted.
    func finish(_ outcome: InsertionOutcome, rendered: RenderedSnippet, snippetID: UUID?) async -> ExpansionResult {
        let result = ExpansionResult(outcome: outcome, copyOffer: outcome.allowsCopyOffer ? rendered : nil)
        if case .replaced = outcome, let snippetID { recordUsageInBackground(snippetID) }
        return result
    }

    /// Resolves once every usage write started so far has finished. For tests and shutdown.
    func waitForUsageRecording() async { await usageRecording?.value }

    /// The input host stays suspended until `finish` returns, so a database write here would drop the user's
    /// next keystrokes. The text is already inserted: a failed write is reported, never turned into a failure.
    private func recordUsageInBackground(_ id: UUID) {
        let previous = usageRecording
        usageRecording = Task { [library] in
            await previous?.value
            do { try await library.recordUsage(id: id) } catch { onUsageRecordFailed?() }
        }
    }

    /// For a target that cannot be inspected: a snippet that needs no answers can still be offered for Copy;
    /// one that needs arguments is not prompted for, because the user would be asked about text we cannot place.
    private func renderWithoutPrompt(_ match: KeywordMatch) async -> RenderedSnippet? {
        guard case .rendered(let rendered)? = try? await library.expansion(for: match, environment: environment()) else { return nil }
        return rendered
    }
}
