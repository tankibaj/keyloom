import Foundation

/// The last state of one record that this Mac and one iCloud account agreed on (the "ancestor" of a
/// three-way comparison), plus the server's opaque version tag. `snapshot` is nil when the agreed state is a
/// deletion.
struct SyncBase: Sendable, Equatable {
    let snapshot: Snippet?
    let systemFields: Data?
}

/// A change the cloud reports. The snippet arrives validated by the transport mapping and is validated again
/// when applied.
enum RemoteChange: Sendable, Equatable {
    case upsert(Snippet, systemFields: Data?)
    case delete(UUID)

    var recordID: UUID {
        switch self {
        case .upsert(let snippet, _): snippet.id
        case .delete(let id): id
        }
    }
}

/// What the cloud should be told about one record: its newest local state (coalescing every queued intent),
/// the server tag the push is based on, and the intents to acknowledge once it is stored.
struct OutgoingChange: Sendable, Equatable {
    enum Payload: Sendable, Equatable {
        case save(Snippet)
        case delete
    }

    let recordID: UUID
    let payload: Payload
    let systemFields: Data?
    let retryIDs: [UUID]
}

struct RemoteApplyResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// The local library already matched, or the change was a replay.
        case unchanged
        case applied
        /// Moved to the trash because the cloud deleted it.
        case deleted
        /// Both sides changed the record; the local side's version lives on as this new snippet.
        case conflictCopied(copyID: UUID)
    }

    let outcome: Outcome
    /// The library rows changed, so derived indexes must reload.
    let libraryChanged: Bool
    /// The incoming snippet's keyword belongs to another enabled snippet, so it was stored disabled.
    let disabledForKeywordConflict: Bool
}

struct SyncPreparation: Sendable, Equatable {
    /// Intents journaled while sync was off, moved into the account's queue.
    let adopted: Int
    /// Snippets that differ from the account's ancestor and had no queued intent.
    let enqueued: Int
    /// A conflict-disabled snippet whose keyword is free was turned back on: the library must reload.
    let reenabled: Bool

    init(adopted: Int, enqueued: Int, reenabled: Bool = false) {
        self.adopted = adopted
        self.enqueued = enqueued
        self.reenabled = reenabled
    }
}

struct OutgoingBatch: Sendable, Equatable {
    let changes: [OutgoingChange]
    /// Settling conflict markers turned a snippet back on: the library must reload.
    let libraryChanged: Bool
}

/// Remote records an engine fetch skipped because a newer Keyloom wrote them: the highest schema version seen and
/// which records. Their local pushes are held back, so an older build never overwrites or deletes them.
struct NewerSchemaMarker: Sendable, Equatable, Codable {
    var version: Int
    var recordIDs: Set<UUID>
}
