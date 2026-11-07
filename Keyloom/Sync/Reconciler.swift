import Foundation

extension Snippet {
    /// The fields that sync. Revision and timestamps are bookkeeping and device-local usage never leaves the Mac,
    /// so none of them decide whether two versions differ. Keywords compare in canonical (NFC) form.
    func hasSameSyncedContent(as other: Snippet) -> Bool {
        name == other.name && icon == other.icon && canonicalKeyword == other.canonicalKeyword
            && enabled == other.enabled && tags == other.tags && pinned == other.pinned && template == other.template
    }

    var canonicalKeyword: String? { keyword?.precomposedStringWithCanonicalMapping }

    /// The trust-boundary check for a record that came from the cloud: the same rules a local save enforces.
    func validatedForSync() throws -> Snippet {
        func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isBlank(name) { throw KeyloomError.invalidSnippet(field: "name", reason: "must not be blank") }
        if let keyword, isBlank(keyword) { throw KeyloomError.invalidSnippet(field: "keyword", reason: "must not be blank") }
        if tags.contains(where: isBlank) { throw KeyloomError.invalidSnippet(field: "tags", reason: "must not be blank") }
        if Set(tags).count != tags.count { throw KeyloomError.invalidSnippet(field: "tags", reason: "must not repeat") }
        try template.validate()
        var checked = self
        checked.keyword = canonicalKeyword
        checked.revision = max(revision, 1)
        return checked
    }
}

/// What this Mac's library already holds for a record, live or in the trash.
struct LocalState: Sendable, Equatable {
    let snippet: Snippet
    let isDeleted: Bool
}

/// What applying one remote change must do. `Reconciler.plan` decides; `SnippetStore.applyRemote` carries it
/// out in a single transaction.
struct RemotePlan: Equatable {
    enum LocalWrite: Equatable {
        case none
        /// Store this live snippet over the row (creating or resurrecting it) without journaling it.
        case save(Snippet)
        /// Move the row to the trash without journaling it.
        case tombstone
    }

    enum BaseUpdate: Equatable {
        /// Same agreed content; only the server's version tag moved.
        case systemFields(Data?)
        case set(Snippet?, systemFields: Data?)
    }

    var local: LocalWrite = .none
    /// A new snippet that keeps the version the cloud's state replaces. It is journaled, so it is uploaded.
    var copy: Snippet?
    /// Queued intents for the record are obsolete: the local row now equals the cloud's state.
    var dropPending = false
    var base: BaseUpdate
    var outcome: RemoteApplyResult.Outcome
    /// Existing local snippets that lose a keyword to the incoming one and are turned off, locally only.
    var disable: [UUID] = []
    /// The incoming snippet itself loses its keyword and is stored turned off, locally only.
    var storedDisabledForConflict = false

    var disabledForKeywordConflict: Bool { storedDisabledForConflict || !disable.isEmpty }
}

/// Three-way reconciliation of one record: local state, the cloud's change, and their agreed ancestor.
///
/// - Nothing is ever lost to a conflict. When both sides changed a record, the cloud's version keeps the
///   record's ID (so every Mac converges on it) and the local version survives as a new, named snippet that
///   syncs like any other. A delete on one side against an edit on the other keeps the delete on the original
///   and the edit as a copy.
/// - Two enabled snippets with one keyword: the earlier-created one keeps it (ties by ID), the same on every Mac.
///   The loser is turned off locally only (it is neither pushed over the cloud's record nor treated as a user edit;
///   the store remembers it as conflict-disabled) so every Mac converges on the same single enabled snippet.
/// - A replay (the cloud repeating what the ancestor already holds) changes nothing.
enum Reconciler {
    struct Context {
        let now: Date
        let makeID: () -> UUID
        /// Whether an enabled, live snippet other than those listed holds this (canonical) keyword.
        /// The enabled, live snippet outside `excluding` that holds this (canonical) keyword, if any.
        let keywordOwner: (_ keyword: String, _ excluding: Set<UUID>) throws -> KeywordOwner?
    }

    struct KeywordOwner: Equatable {
        let id: UUID
        let createdAt: Date
    }

    static func plan(_ change: RemoteChange, local: LocalState?, base: SyncBase?, context: Context) throws -> RemotePlan {
        switch change {
        case .upsert(let remote, let fields): try planUpsert(remote, fields: fields, local: local, base: base, context: context)
        case .delete: try planDelete(local: local, base: base, context: context)
        }
    }

    // MARK: Upsert

    private static func planUpsert(_ remote: Snippet, fields: Data?, local: LocalState?, base: SyncBase?,
                                   context: Context) throws -> RemotePlan {
        if let agreed = base?.snapshot, agreed.hasSameSyncedContent(as: remote) {
            return RemotePlan(base: .systemFields(fields), outcome: .unchanged)
        }
        guard let local else {
            let adoption = try adopting(remote, over: nil, context: context)
            return RemotePlan(local: .save(adoption.stored), base: .set(remote, systemFields: fields), outcome: .applied,
                              disable: adoption.displaced, storedDisabledForConflict: adoption.disabled)
        }
        if !local.isDeleted, local.snippet.hasSameSyncedContent(as: remote) {
            return RemotePlan(dropPending: true, base: .set(remote, systemFields: fields), outcome: .unchanged)
        }
        let adoption = try adopting(remote, over: local.snippet, context: context)
        let stored = adoption.stored
        guard changedLocally(local, since: base) else {
            return RemotePlan(local: .save(stored), dropPending: true, base: .set(remote, systemFields: fields),
                              outcome: .applied, disable: adoption.displaced, storedDisabledForConflict: adoption.disabled)
        }
        if local.isDeleted {
            // Deleted here, edited there: the delete stays queued; the edit lives on as a copy.
            let copy = try conflictCopy(of: remote, reserving: nil, excluding: [remote.id], context: context)
            return RemotePlan(copy: copy, base: .set(remote, systemFields: fields), outcome: .conflictCopied(copyID: copy.id))
        }
        let copy = try conflictCopy(of: local.snippet, reserving: stored.enabled ? stored.keyword : nil,
                                excluding: [local.snippet.id], context: context)
        return RemotePlan(local: .save(stored), copy: copy, dropPending: true, base: .set(remote, systemFields: fields),
                          outcome: .conflictCopied(copyID: copy.id), disable: adoption.displaced,
                          storedDisabledForConflict: adoption.disabled)
    }

    // MARK: Delete

    private static func planDelete(local: LocalState?, base: SyncBase?, context: Context) throws -> RemotePlan {
        let deleted = RemotePlan.BaseUpdate.set(nil, systemFields: nil)
        guard let local else { return RemotePlan(base: deleted, outcome: .unchanged) }
        if local.isDeleted { return RemotePlan(dropPending: true, base: deleted, outcome: .unchanged) }
        // A record this Mac never agreed on, or already knew as deleted, is a different history: keep it.
        guard let agreed = base?.snapshot else { return RemotePlan(base: deleted, outcome: .unchanged) }
        if local.snippet.hasSameSyncedContent(as: agreed) {
            return RemotePlan(local: .tombstone, dropPending: true, base: deleted, outcome: .deleted)
        }
        let copy = try conflictCopy(of: local.snippet, reserving: nil, excluding: [local.snippet.id], context: context)
        return RemotePlan(local: .tombstone, copy: copy, dropPending: true, base: deleted,
                          outcome: .conflictCopied(copyID: copy.id))
    }

    // MARK: Helpers

    /// Whether the local row moved away from what this Mac and the account last agreed on.
    private static func changedLocally(_ local: LocalState, since base: SyncBase?) -> Bool {
        guard let base else { return true }
        guard let agreed = base.snapshot else { return !local.isDeleted }
        return local.isDeleted || !local.snippet.hasSameSyncedContent(as: agreed)
    }

    private struct Adoption {
        let stored: Snippet
        /// The snippet had to be stored turned off: it loses its keyword to an existing snippet.
        let disabled: Bool
        /// Existing snippets that lose their keyword to this one.
        let displaced: [UUID]
    }

    /// The remote snippet as this Mac stores it: the revision continues the local counter. When another enabled
    /// snippet holds the same keyword, the earlier-created one keeps it (ties by ID), so every Mac turns off the
    /// same snippet; the loser is turned off locally and the cloud's record keeps the user's enabled state.
    private static func adopting(_ remote: Snippet, over local: Snippet?, context: Context) throws -> Adoption {
        var stored = remote
        stored.revision = (local?.revision ?? 0) + 1
        guard stored.enabled, let keyword = stored.canonicalKeyword,
              let owner = try context.keywordOwner(keyword, [stored.id]) else {
            return Adoption(stored: stored, disabled: false, displaced: [])
        }
        if precedes((stored.createdAt, stored.id), (owner.createdAt, owner.id)) {
            return Adoption(stored: stored, disabled: false, displaced: [owner.id])
        }
        stored.enabled = false
        return Adoption(stored: stored, disabled: true, displaced: [])
    }

    private static func precedes(_ lhs: (Date, UUID), _ rhs: (Date, UUID)) -> Bool {
        lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.uuidString < rhs.1.uuidString
    }

    /// A new snippet holding `source`'s content. Named so the user can tell where it came from, and disabled
    /// when its keyword would duplicate an enabled one.
    private static func conflictCopy(of source: Snippet, reserving reserved: String?, excluding: Set<UUID>,
                                     context: Context) throws -> Snippet {
        let id = context.makeID()
        var copy = Snippet(id: id, name: "\(source.name) (conflict copy \(day(context.now)))", icon: source.icon,
                           keyword: source.canonicalKeyword, enabled: source.enabled, tags: source.tags, pinned: false,
                           revision: 1, template: source.template, createdAt: context.now)
        if copy.enabled, let keyword = copy.canonicalKeyword,
           try keyword == reserved || context.keywordOwner(keyword, excluding.union([id])) != nil {
            copy.enabled = false
        }
        return copy
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
