import Foundation

/// A committed change to the library, published by `SnippetLibrary.changes` after the derived state
/// (matcher index, search index, snapshot) already reflects it. Payloads are IDs only: no snippet text.
enum LibraryChange: Equatable, Sendable {
    case created(UUID)
    /// Content edit, rename or pin change.
    case updated(UUID)
    case deleted(UUID)
    /// Back from the trash, by undo or restore.
    case restored(UUID)
    case usageRecorded(UUID)
}

/// The sidebar and menu views over the library.
enum LibraryFilter: Equatable, Sendable {
    case all
    /// Snippets used at least once, most recently used first (ignores search rank).
    case recentlyUsed
    case pinned
    case tag(String)
}

/// What the editor shows next to the keyword field. Keywords are judged as the matcher indexes them: enabled,
/// non-empty, NFC, case-sensitive.
struct KeywordDiagnostics: Equatable, Sendable {
    /// Two or more enabled snippets sharing a keyword. Local writes refuse this (`StoreError.keywordConflict`);
    /// it can still arrive through sync or import.
    let conflicts: [KeywordConflict]
    let overlaps: [KeywordOverlap]
    /// Snippets whose active keyword is longer than `KeywordIndex.maxKeywordScalars`; the matcher ignores them.
    let oversizeKeywordSnippetIDs: [UUID]
}

/// Result of asking to expand a snippet: either the user must answer arguments first, or it is rendered.
enum ExpansionOutcome: Equatable, Sendable {
    /// Arguments with no answer yet, in order of first appearance; defaults and choices prefill the prompt.
    case needsArguments([ArgumentRequirement])
    case rendered(RenderedSnippet)
}
