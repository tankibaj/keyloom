import Foundation
import os

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
    /// iCloud sync added, changed or removed snippets; observers should reload.
    case remoteChangesApplied
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

/// Fans committed changes out to any number of subscribers. Each subscriber's stream is independent: ending
/// one (its task was cancelled) removes only that one.
final class ChangeBroadcaster: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func stream() -> AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryChange.self)
        let id = UUID()
        let finished = state.withLock { state -> Bool in
            if !state.isFinished { state.subscribers[id] = continuation }
            return state.isFinished
        }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.subscribers[id] = nil } }
        }
        return stream
    }

    func yield(_ change: LibraryChange) {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers { subscriber.yield(change) }
    }

    func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<LibraryChange>.Continuation] in
            state.isFinished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.finish() }
    }
}
