import Foundation
import Observation

/// The editor's on-device assistance action: Proofread, Shorten or Change Tone on the selected prose, a preview,
/// then Apply or Cancel. Everything goes through `AssistanceService`, which asks the policy before and after the
/// model runs, so with assistance off, managed off or the model not ready no request is made. The model is only
/// reached from `request`, an explicit user action: typing and search never get here. Prose and suggestions
/// pass through memory only and are never logged.
@MainActor @Observable
final class AssistanceEditorModel {
    enum State: Equatable {
        case idle
        case working
        case proposed(EditPreview)
        /// Said to the user; the document is unchanged.
        case failed(String)
    }

    private(set) var state = State.idle

    /// Weak: the editor owns this model (`EditorViewModel.assistance`), so a strong reference would be a retain cycle.
    @ObservationIgnored private weak var editor: EditorViewModel?
    @ObservationIgnored private let service: AssistanceService
    @ObservationIgnored private let policy: WritingAssistancePolicy
    @ObservationIgnored private var proposal: ProposedEdit?

    init(editor: EditorViewModel, service: AssistanceService, policy: WritingAssistancePolicy) {
        self.editor = editor
        self.service = service
        self.policy = policy
    }

    /// The menu is shown only while the policy permits on-device edits.
    var isOffered: Bool { policy.snapshot.permitsOnDeviceEdits }

    var canRequest: Bool {
        guard isOffered, editor?.bodyController.hasSelection == true else { return false }
        if case .working = state { return false }
        return true
    }

    var canApply: Bool {
        // The planner rebuilds runs around the selection, so its own `hasChanges` is true even for an identical
        // reply; what the user can see is whether the words differ.
        if case .proposed(let preview) = state { preview.originalText != preview.proposedText } else { false }
    }

    /// What Settings says when assistance is on but the OS cannot run it; nil when ready or off.
    var unavailableNote: String? {
        let status = policy.snapshot.assistance
        switch status {
        case .off, .ready, .managedOff: return nil
        default: return AssistanceCopy.assistanceStatus(status)
        }
    }

    func request(_ action: EditAction) async {
        guard canRequest, let editor, let selection = editor.bodyController.selectionInDocument() else { return }
        let request = EditRequest(action: action, document: editor.draft.body, revision: editor.bodyRevision, selection: selection)
        state = .working
        do {
            let edit = try await service.propose(request)
            proposal = edit
            state = .proposed(edit.preview)
        } catch {
            proposal = nil
            state = Self.state(for: error)
        }
    }

    /// One undoable edit in the text view. A suggestion made for an older text or selection is refused.
    func apply() async {
        guard canApply, let edit = proposal else { return }
        guard let editor, let selection = editor.bodyController.selectionInDocument() else {
            proposal = nil
            state = Self.state(for: AssistanceError.stale)
            return
        }
        do {
            let payload = try await service.apply(edit, currentRevision: editor.bodyRevision, currentSelection: selection)
            editor.bodyController.applySuggestion(payload)
            proposal = nil
            state = .idle
        } catch {
            proposal = nil
            state = Self.state(for: error)
        }
    }

    /// Drops the suggestion, and the request if one is still running.
    func cancel() {
        proposal = nil
        state = .idle
        let service = service
        Task { await service.cancel() }
    }

    /// The policy changed (switched off, managed off): nothing pending may survive.
    func policyChanged() {
        guard !isOffered else { return }
        cancel()
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private static func state(for error: any Error) -> State {
        guard let error = error as? AssistanceError else { return .failed("Keyloom couldn’t get a suggestion. Your text is unchanged.") }
        switch error {
        case .cancelled: return .idle
        case .notPermitted(let status): return .failed(AssistanceCopy.assistanceStatus(status))
        case .emptySelection: return .failed("Select some text first.")
        case .selectionSpansParagraphs: return .failed("Select text within one paragraph.")
        case .selectionSplitsToken: return .failed("The selection cuts through a placeholder. Select the whole placeholder or only the words.")
        case .selectionNotProse: return .failed("Select some words, not only placeholders.")
        case .selectionTooLarge: return .failed("That selection is too long. Select less text.")
        case .selectionContainsReservedMarkers: return .failed("The selection contains characters Keyloom reserves for placeholders.")
        case .rejectedSuggestion: return .failed("The suggestion changed or lost a placeholder, so Keyloom discarded it. Your text is unchanged.")
        case .modelFailed(.unsupportedLanguage): return .failed("The on-device model doesn’t support this language.")
        case .modelFailed(.contextTooLarge): return .failed("That selection is too long for the on-device model.")
        case .modelFailed: return .failed("The on-device model couldn’t suggest a change. Your text is unchanged.")
        case .stale: return .failed("The text changed since the suggestion was made, so it was discarded. Try again.")
        }
    }
}
