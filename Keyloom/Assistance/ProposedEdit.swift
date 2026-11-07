import Foundation

enum EditTone: String, CaseIterable, Sendable {
    case professional, friendly, casual
}

/// What the user explicitly asked for on the selected prose.
enum EditAction: Equatable, Sendable {
    case proofread
    case shorten
    case changeTone(EditTone)
}

/// An explicit request. `selection` is in UTF-16 offsets of `document.plainText` (paragraphs joined by
/// newlines, tokens as their source); the editor maps its own selection to that. `revision` is the editor's
/// document revision when the request was made.
struct EditRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let action: EditAction
    let document: Document
    let revision: Int
    let selection: ValidatedUTF16Range

    /// Never includes the document: it holds the user's prose.
    var description: String { "EditRequest(\(action), revision: \(revision), selection: \(selection.start)..<\(selection.end))" }
    var debugDescription: String { description }
}

/// Text for the preview. Holds the user's prose, so it is never logged.
struct EditPreview: Equatable, Sendable {
    let originalText: String
    let proposedText: String
    /// `false` when the model found nothing to change, so Apply would be a no-op.
    let hasChanges: Bool
}

/// Everything the editor needs to put the original back.
struct UndoPayload: Equatable, Sendable {
    let document: Document
    /// The selection as it was before the edit.
    let selection: ValidatedUTF16Range
}

/// Everything the editor needs to apply the edit as one undoable step.
struct ApplyPayload: Equatable, Sendable {
    /// The whole new document, validated; tokens and formatting outside the selection are unchanged.
    let document: Document
    /// The replaced text in the new document's plain text, to select after applying.
    let selection: ValidatedUTF16Range
    let baseRevision: Int
    let undo: UndoPayload
}

/// A validated suggestion, held by `AssistanceService` until it is applied, cancelled or discarded.
/// Cancel is `AssistanceService.cancel()`; Apply is `AssistanceService.apply`, which re-checks it is current.
struct ProposedEdit: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let action: EditAction
    let baseRevision: Int
    let originalSelection: ValidatedUTF16Range
    let preview: EditPreview
    let applyPayload: ApplyPayload

    var description: String { "ProposedEdit(\(id), \(action), revision: \(baseRevision))" }
    var debugDescription: String { description }
}

/// Why a model reply was refused. Payloads never carry text.
enum RejectionReason: Equatable, Sendable {
    case tokenDropped
    case tokenDuplicated
    case tokenReordered
    /// A placeholder the app did not give the model, or one that is broken.
    case malformedPlaceholder
    /// Token syntax (`{`) the model wrote where the selection had none.
    case tokenSyntaxIntroduced
    /// Defence in depth: the rebuilt document's tokens differ from the original's.
    case tokenAltered
    case emptyResult
    case multiParagraphResult
    case invalidDocument
}

enum ModelFailure: Equatable, Sendable {
    case unsupportedLanguage
    case contextTooLarge
    case refused
    case other
}

/// Thrown by a model session; the service turns it into `AssistanceError.modelFailed`.
struct ModelSessionError: Error, Equatable, Sendable {
    let failure: ModelFailure
}

/// Typed failures of the assistance pipeline. Payloads never carry prompts, prose or token text.
enum AssistanceError: Error, Equatable, Sendable {
    case notPermitted(AssistanceState)
    case emptySelection
    case selectionSpansParagraphs
    case selectionSplitsToken
    /// No prose to edit: only whitespace and tokens.
    case selectionNotProse
    case selectionTooLarge(maximum: Int)
    /// The selection already contains the placeholder markers the prompt uses.
    case selectionContainsReservedMarkers
    case rejectedSuggestion(RejectionReason)
    case modelFailed(ModelFailure)
    /// The suggestion no longer matches the editor (revision or selection changed) or was discarded.
    case stale
    case cancelled
}
