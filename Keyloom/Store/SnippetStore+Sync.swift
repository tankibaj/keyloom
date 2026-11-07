import Foundation

/// The store's side of private iCloud sync. Everything is scoped to one account: an account's engine state,
/// ancestors and queue are never read or written for another, and nothing here deletes library rows except
/// applying a remote delete, which moves the snippet to the trash.
///
/// Each method is one transaction, so a crash leaves either the whole step or none of it:
/// - `applyRemote` writes the library change, the conflict copy, the queue clean-up and the new ancestor together.
/// - `recordSent` acknowledges the queue and records the ancestor together. If the app dies between the cloud
///   storing a record and `recordSent`, the intent is still queued and is sent again with the same retry
///   identity; the cloud answers with its stored record, which `applyRemote` recognizes as already agreed.
///
/// Snippet text is only bound as parameters and never put in an error.
extension SnippetStore {
    /// The account local intents are journaled under while no iCloud account is syncing.
    static let localSyncAccount = "local"

    // MARK: Engine state

    func syncEngineState(account: String) throws -> Data? {
        try Self.validateAccount(account)
        return try read { db in
            try db.first("SELECT state FROM sync_engine_state WHERE account = ?", [.text(account)]) { $0.data(0) }
        }
    }

    func saveSyncEngineState(_ state: Data, account: String) throws {
        try Self.validateAccount(account)
        _ = try write { db in
            try db.run("INSERT OR REPLACE INTO sync_engine_state (account, state) VALUES (?, ?)", [.text(account), .blob(state)])
        }
    }

    /// Forgets one account's engine state and ancestors (its iCloud data was reset). The library and the
    /// queue stay, so the next start uploads whatever the account no longer has.
    func resetSyncMetadata(account: String) throws {
        try Self.validateAccount(account)
        try write { db in
            try db.run("DELETE FROM sync_engine_state WHERE account = ?", [.text(account)])
            try db.run("DELETE FROM sync_records WHERE account = ?", [.text(account)])
        }
    }

    func syncBase(account: String, id: UUID) throws -> SyncBase? {
        try Self.validateAccount(account)
        return try read { db in try syncBase(db, account: account, id: id) }
    }

    func pendingCount(account: String) throws -> Int {
        try Self.validateAccount(account)
        return try read { db in
            try db.first("SELECT count(*) FROM sync_outbox WHERE account = ?", [.text(account)]) { $0.int(0) } ?? 0
        }
    }

    // MARK: Starting and pushing

    /// Run when sync starts for `account`. Moves the intents journaled while sync was off into the account's
    /// queue, then queues every snippet that differs from the account's ancestor and has no intent yet, so
    /// edits made while off, under another account or by a restore are found by comparing state, not by trusting
    /// the journal. A snippet that another account owns (it has an ancestor or a queued intent there and no
    /// ancestor here) is never queued for this account, and its local intents stay where they are.
    func prepareSync(account: String) throws -> SyncPreparation {
        try Self.validateAccount(account)
        guard account != Self.localSyncAccount else { throw StoreError.invalidAccount }
        return try write { db in
            let adopted = try db.run("""
            UPDATE sync_outbox SET account = ?1 WHERE account = '\(Self.localSyncAccount)' AND record_id NOT IN (\(Self.ownedByOtherAccounts))
            """, [.text(account)])
            let foreign = Set(try db.rows(Self.ownedByOtherAccounts, [.text(account)]) { $0.string(0) })
            let queued = Set(try db.rows("SELECT DISTINCT record_id FROM sync_outbox WHERE account = ?", [.text(account)]) {
                $0.string(0)
            })
            var enqueued = 0
            let settled = try syncSettleMarkers(db)
            let forced = settled.forced
            for row in try syncRows(db).rows {
                let key = row.snippet.id.uuidString
                guard !foreign.contains(key), !queued.contains(key) else { continue }
                let base = try syncBase(db, account: account, id: row.snippet.id)
                let differs: Bool
                if row.deletedAt != nil {
                    differs = base?.snapshot != nil
                } else if let agreed = base?.snapshot {
                    differs = !Self.syncNormalized(row.snippet, forced: forced).hasSameSyncedContent(as: agreed)
                } else {
                    differs = true
                }
                guard differs else { continue }
                try syncJournal(db, account: account, id: row.snippet.id, operation: row.deletedAt == nil ? .upsert : .delete,
                                revision: row.snippet.revision)
                enqueued += 1
            }
            return SyncPreparation(adopted: adopted, enqueued: enqueued, reenabled: settled.reenabled)
        }
    }

    /// The next changes to push, oldest first, one per record carrying its newest state. Intents that would
    /// change nothing (the cloud already agrees, or the record was created and deleted before any sync) and
    /// intents for records another account owns are acknowledged here instead of being sent.
    func nextOutgoing(account: String, limit: Int) throws -> [OutgoingChange] {
        try nextOutgoingBatch(account: account, limit: limit).changes
    }

    /// `nextOutgoing`, also saying whether settling conflict markers turned a snippet back on, so the caller can
    /// reload the library.
    func nextOutgoingBatch(account: String, limit: Int) throws -> OutgoingBatch {
        try Self.validateAccount(account)
        return try write { db in
            let foreign = Set(try db.rows(Self.ownedByOtherAccounts, [.text(account)]) { $0.string(0) })
            var order: [UUID] = []
            var intents: [UUID: [OutboxEntry]] = [:]
            for entry in try pending(account: account, limit: Int(Int32.max)) {
                if intents[entry.recordID] == nil { order.append(entry.recordID) }
                intents[entry.recordID, default: []].append(entry)
            }
            var changes: [OutgoingChange] = []
            let settled = try syncSettleMarkers(db)
            let forced = settled.forced
            for id in order where changes.count < limit {
                let retryIDs = (intents[id] ?? []).map(\.retryID)
                func discard() throws {
                    try db.run("DELETE FROM sync_outbox WHERE account = ? AND record_id = ?", [.text(account), .uuid(id)])
                }
                if foreign.contains(id.uuidString) { try discard(); continue }
                let found = try syncRows(db, id: id)
                guard found.unreadable == 0 else { continue }
                let base = try syncBase(db, account: account, id: id)
                if let row = found.rows.first, row.deletedAt == nil {
                    let snippet = Self.syncNormalized(row.snippet, forced: forced)
                    if let agreed = base?.snapshot, agreed.hasSameSyncedContent(as: snippet) { try discard(); continue }
                    changes.append(OutgoingChange(recordID: id, payload: .save(snippet), systemFields: base?.systemFields,
                                                  retryIDs: retryIDs))
                } else if base?.snapshot != nil {
                    changes.append(OutgoingChange(recordID: id, payload: .delete, systemFields: base?.systemFields,
                                                  retryIDs: retryIDs))
                } else {
                    try discard()
                }
            }
            return OutgoingBatch(changes: changes, libraryChanged: settled.reenabled)
        }
    }

    /// The cloud stored `change`: acknowledges exactly the intents it carried and records what was sent as the
    /// agreed ancestor. Newer intents (an edit made while the push was in flight) stay queued. Repeating it is a no-op.
    func recordSent(_ change: OutgoingChange, systemFields: Data?, account: String) throws {
        try Self.validateAccount(account)
        try write { db in
            for retryID in change.retryIDs {
                try db.run("DELETE FROM sync_outbox WHERE retry_id = ? AND account = ?", [.uuid(retryID), .text(account)])
            }
            switch change.payload {
            case .save(let sent): try syncSetBase(db, account: account, id: change.recordID, snapshot: sent, systemFields: systemFields)
            case .delete: try syncSetBase(db, account: account, id: change.recordID, snapshot: nil, systemFields: nil)
            }
        }
    }

    /// Counts a failed push for every intent of one change; their retry identities are kept.
    func markFailed(retryIDs: [UUID], account: String) throws {
        try Self.validateAccount(account)
        try write { db in
            for retryID in retryIDs {
                try db.run("""
                UPDATE sync_outbox SET attempts = attempts + 1, last_attempt_at = ? WHERE retry_id = ? AND account = ?
                """, [.date(now()), .uuid(retryID), .text(account)])
            }
        }
    }

    // MARK: Pulling

    /// Reconciles one change from `account`'s cloud with the library in a single transaction (see
    /// `Reconciler`). Throws `KeyloomError.invalidSnippet` for an invalid remote snippet and
    /// `StoreError.corruptRecord` when the local row cannot be read; in both cases nothing is written.
    func applyRemote(_ change: RemoteChange, account: String) throws -> RemoteApplyResult {
        try Self.validateAccount(account)
        let checked: RemoteChange
        switch change {
        case .upsert(let snippet, let fields): checked = .upsert(try snippet.validatedForSync(), systemFields: fields)
        case .delete: checked = change
        }
        return try write { db in
            let id = checked.recordID
            // Settle first: a loser whose keyword was freed must be read as the enabled snippet it is again,
            // or it would look edited against its ancestor and produce a spurious conflict copy.
            let settled = try syncSettleMarkers(db)
            var reenabled = settled.reenabled
            let forced = settled.forced
            let found = try syncRows(db, id: id)
            guard found.unreadable == 0 else { throw StoreError.corruptRecord(column: "template") }
            let local = found.rows.first.map {
                LocalState(snippet: Self.syncNormalized($0.snippet, forced: forced), isDeleted: $0.deletedAt != nil)
            }
            let context = Reconciler.Context(now: now(), makeID: makeID) { keyword, excluding in
                try self.syncKeywordOwner(db, keyword, excluding: excluding)
            }
            let plan = try Reconciler.plan(checked, local: local, base: try syncBase(db, account: account, id: id), context: context)

            // Losers first: the unique index allows one enabled snippet per keyword.
            for loserID in plan.disable {
                guard var loser = try syncRows(db, id: loserID).rows.first?.snippet else { continue }
                loser.enabled = false
                loser.revision += 1
                loser.updatedAt = now()
                try syncSave(db, loser)
                try syncMarkForced(db, loserID, revision: loser.revision)
            }
            switch plan.local {
            case .none: break
            case .save(let snippet):
                try syncSave(db, snippet)
                if plan.storedDisabledForConflict {
                    try syncMarkForced(db, id, revision: snippet.revision)
                } else {
                    try db.run("DELETE FROM sync_conflict_disabled WHERE record_id = ?", [.uuid(id)])
                }
            case .tombstone:
                try db.run("DELETE FROM sync_conflict_disabled WHERE record_id = ?", [.uuid(id)])
                let moment = SQLValue.date(now())
                try db.run("UPDATE snippets SET deleted_at = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           [moment, moment, .uuid(id)])
            }
            if let copy = plan.copy {
                try syncSave(db, copy)
                try syncJournal(db, account: account, id: copy.id, operation: .upsert, revision: copy.revision)
            }
            if plan.dropPending {
                try db.run("DELETE FROM sync_outbox WHERE account = ? AND record_id = ?", [.text(account), .uuid(id)])
            }
            switch plan.base {
            case .systemFields(let fields):
                try db.run("UPDATE sync_records SET system_fields = ? WHERE account = ? AND record_id = ?",
                           [fields.map(SQLValue.blob) ?? .null, .text(account), .uuid(id)])
            case .set(let snapshot, let fields):
                try syncSetBase(db, account: account, id: id, snapshot: snapshot, systemFields: fields)
            }
            // A keyword this change freed (its owner was deleted, turned off or re-keyed) goes back to its losers.
            reenabled = try syncSettleMarkers(db).reenabled || reenabled
            return RemoteApplyResult(outcome: plan.outcome, libraryChanged: plan.local != .none || plan.copy != nil || reenabled,
                                     disabledForKeywordConflict: plan.disabledForKeywordConflict)
        }
    }

    /// Snippets sync turned off because another snippet holds their keyword (and still does): for a notice.
    func keywordConflictDisabledIDs() throws -> [UUID] {
        try read { db in try syncSettleMarkers(db, apply: false).forced.sorted { $0.uuidString < $1.uuidString } }
    }

    // MARK: Private

    private static let syncColumns = """
    id, name, icon_kind, icon_value, keyword, enabled, pinned, revision, template, created_at, updated_at, deleted_at
    """

    /// Record IDs that belong to another iCloud account and not to `?1`: the other account has an ancestor for
    /// them or still has an intent queued, and `?1` has no ancestor. Intents under `local` mean nothing here:
    /// the local library is not an account.
    private static let ownedByOtherAccounts = """
    SELECT record_id FROM sync_records WHERE account != ?1
    UNION SELECT record_id FROM sync_outbox WHERE account NOT IN (?1, '\(localSyncAccount)')
    EXCEPT SELECT record_id FROM sync_records WHERE account = ?1
    """

    private struct SyncRow {
        let snippet: Snippet
        let deletedAt: Date?
    }

    /// Readable rows (live and trashed), one record or all, and how many rows could not be decoded.
    private func syncRows(_ db: SQLiteConnection, id: UUID? = nil) throws -> (rows: [SyncRow], unreadable: Int) {
        let condition = id == nil ? "1 = 1" : "id = ?"
        let parameters = id.map { [SQLValue.uuid($0)] } ?? []
        var tagsByID: [String: [String]] = [:]
        _ = try db.rows("""
        SELECT snippet_id, tag FROM snippet_tags WHERE snippet_id IN (SELECT id FROM snippets WHERE \(condition))
        ORDER BY snippet_id, position
        """, parameters) { tagsByID[$0.string(0), default: []].append($0.string(1)) }
        var rows: [SyncRow] = []
        var unreadable = 0
        _ = try db.rows("SELECT \(Self.syncColumns) FROM snippets WHERE \(condition) ORDER BY created_at, id", parameters) { row in
            guard let rowID = UUID(uuidString: row.string(0)), let template = try? Document.decode(from: row.data(8)) else {
                unreadable += 1
                return
            }
            let icon: SnippetIcon = row.string(2) == "emoji" ? .emoji(row.string(3)) : .symbol(row.string(3))
            let snippet = Snippet(id: rowID, name: row.string(1), icon: icon, keyword: row.isNull(4) ? nil : row.string(4),
                                  enabled: row.int(5) == 1, tags: tagsByID[row.string(0)] ?? [], pinned: row.int(6) == 1,
                                  revision: row.int(7), template: template, createdAt: row.date(9), updatedAt: row.date(10))
            rows.append(SyncRow(snippet: snippet, deletedAt: row.isNull(11) ? nil : row.date(11)))
        }
        return (rows, unreadable)
    }

    private func syncBase(_ db: SQLiteConnection, account: String, id: UUID) throws -> SyncBase? {
        try db.first("SELECT snapshot, system_fields FROM sync_records WHERE account = ? AND record_id = ?",
                     [.text(account), .uuid(id)]) { row in
            var snapshot: Snippet?
            if !row.isNull(0) {
                guard let decoded = try? JSONDecoder().decode(Snippet.self, from: row.data(0)) else {
                    throw StoreError.corruptRecord(column: "sync_records")
                }
                snapshot = decoded
            }
            return SyncBase(snapshot: snapshot, systemFields: row.isNull(1) ? nil : row.data(1))
        }
    }

    private func syncSetBase(_ db: SQLiteConnection, account: String, id: UUID, snapshot: Snippet?, systemFields: Data?) throws {
        let encoded = try snapshot.map { SQLValue.blob(try JSONEncoder().encode($0)) } ?? .null
        try db.run("INSERT OR REPLACE INTO sync_records (account, record_id, snapshot, system_fields) VALUES (?, ?, ?, ?)",
                   [.text(account), .uuid(id), encoded, systemFields.map(SQLValue.blob) ?? .null])
    }

    /// The enabled, live snippet outside `excluding` that holds this (canonical) keyword.
    private func syncKeywordOwner(_ db: SQLiteConnection, _ keyword: String, excluding: Set<UUID>) throws -> Reconciler.KeywordOwner? {
        let owners = try db.rows("SELECT id, created_at FROM snippets WHERE keyword = ? AND enabled = 1 AND deleted_at IS NULL",
                                 [.text(keyword)]) { row in (row.string(0), row.date(1)) }
        return owners.compactMap { text, createdAt in
            UUID(uuidString: text).flatMap { id in excluding.contains(id) ? nil : Reconciler.KeywordOwner(id: id, createdAt: createdAt) }
        }.first
    }

    private func syncMarkForced(_ db: SQLiteConnection, _ id: UUID, revision: Int) throws {
        try db.run("INSERT OR REPLACE INTO sync_conflict_disabled (record_id, revision) VALUES (?, ?)", [.uuid(id), .int(Int64(revision))])
    }

    /// Brings the conflict-disabled markers up to date and returns the snippets that are still forced off.
    /// A marker survives only while the snippet is still live, still disabled and nothing the user did since has
    /// enabled it (a stale marker would hide a later deliberate disable). A forced snippet whose keyword is free
    /// again (the owner was deleted, turned off or re-keyed) is turned back on, locally and without journaling:
    /// its ancestor already says enabled, so nothing is pushed and every Mac ends up the same. Earliest first, so
    /// the same snippet wins here as in `Reconciler`.
    private func syncSettleMarkers(_ db: SQLiteConnection, apply: Bool = true) throws -> (forced: Set<UUID>, reenabled: Bool) {
        let markers = try db.rows("""
        SELECT f.record_id, f.revision FROM sync_conflict_disabled f LEFT JOIN snippets s ON s.id = f.record_id
        ORDER BY s.created_at, f.record_id
        """) { row in (UUID(uuidString: row.string(0)), row.int(1)) }
        var forced = Set<UUID>()
        var reenabled = false
        for (maybeID, markerRevision) in markers {
            guard let id = maybeID else { continue }
            func drop() throws { if apply { try db.run("DELETE FROM sync_conflict_disabled WHERE record_id = ?", [.uuid(id)]) } }
            let found = try syncRows(db, id: id)
            guard found.unreadable == 0 else { continue }
            guard let row = found.rows.first, row.deletedAt == nil, !row.snippet.enabled,
                  try syncMarkerIsCurrent(db, id, markerRevision: markerRevision, currentRevision: row.snippet.revision, apply: apply) else {
                try drop()
                continue
            }
            if let keyword = row.snippet.canonicalKeyword, try syncKeywordOwner(db, keyword, excluding: [id]) != nil {
                forced.insert(id)
                continue
            }
            guard apply else { continue } // read-only: a freed loser is neither forced nor changed here
            var restored = row.snippet
            restored.enabled = true
            restored.revision += 1
            restored.updatedAt = now()
            try syncSave(db, restored)
            try drop()
            reenabled = true
        }
        return (forced, reenabled)
    }

    /// The snippet has not been enabled since the marker was written: either untouched, or every later revision in
    /// its history is still disabled (a tag edit, say). A history gap counts as stale: when unsure, the disable
    /// is treated as the user's own.
    private func syncMarkerIsCurrent(_ db: SQLiteConnection, _ id: UUID, markerRevision: Int, currentRevision: Int,
                                     apply: Bool) throws -> Bool {
        if markerRevision == currentRevision { return true }
        guard currentRevision > markerRevision else { return false }
        let later = try db.rows("SELECT snapshot FROM snippet_revisions WHERE snippet_id = ? AND revision > ? ORDER BY revision",
                                [.uuid(id), .int(Int64(markerRevision))]) { $0.data(0) }
        guard later.count == currentRevision - markerRevision else { return false }
        for snapshot in later {
            guard let decoded = try? JSONDecoder().decode(Snippet.self, from: snapshot), !decoded.enabled else { return false }
        }
        if apply { try db.run("UPDATE sync_conflict_disabled SET revision = ? WHERE record_id = ?", [.int(Int64(currentRevision)), .uuid(id)]) }
        return true
    }

    /// A snippet that sync itself turned off for a keyword conflict is compared and sent as the user left it
    /// (enabled): the forced state is local, so it is never mistaken for an edit nor pushed over iCloud.
    private static func syncNormalized(_ snippet: Snippet, forced: Set<UUID>) -> Snippet {
        guard !snippet.enabled, forced.contains(snippet.id) else { return snippet }
        var intended = snippet
        intended.enabled = true
        return intended
    }

    /// Inserts or overwrites the live row for `snippet`, with its tags and a history snapshot. Local usage
    /// (last used, count) of an existing row is kept. Never journals.
    private func syncSave(_ db: SQLiteConnection, _ snippet: Snippet) throws {
        let (iconKind, iconValue): (String, String) = switch snippet.icon {
        case .emoji(let value): ("emoji", value)
        case .symbol(let value): ("symbol", value)
        }
        try db.run("""
        INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, pinned, revision, template, created_at,
                              updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT (id) DO UPDATE SET name = excluded.name, icon_kind = excluded.icon_kind,
            icon_value = excluded.icon_value, keyword = excluded.keyword, enabled = excluded.enabled,
            pinned = excluded.pinned, revision = excluded.revision, template = excluded.template,
            created_at = excluded.created_at, updated_at = excluded.updated_at, deleted_at = NULL
        """, [.uuid(snippet.id), .text(snippet.name), .text(iconKind), .text(iconValue), .text(orNull: snippet.keyword),
              .bool(snippet.enabled), .bool(snippet.pinned), .int(Int64(snippet.revision)), .blob(try snippet.template.encoded()),
              .date(snippet.createdAt), .date(snippet.updatedAt)])
        try db.run("DELETE FROM snippet_tags WHERE snippet_id = ?", [.uuid(snippet.id)])
        for (position, tag) in snippet.tags.enumerated() {
            try db.run("INSERT INTO snippet_tags (snippet_id, tag, position) VALUES (?, ?, ?)",
                       [.uuid(snippet.id), .text(tag), .int(Int64(position))])
        }
        try db.run("INSERT OR REPLACE INTO snippet_revisions (snippet_id, revision, recorded_at, snapshot) VALUES (?, ?, ?, ?)",
                   [.uuid(snippet.id), .int(Int64(snippet.revision)), .date(now()), .blob(try JSONEncoder().encode(snippet))])
        try db.run("DELETE FROM snippet_revisions WHERE snippet_id = ? AND revision <= ?",
                   [.uuid(snippet.id), .int(Int64(snippet.revision - Self.maxRevisionsPerSnippet))])
    }

    /// Like `journal`, for an explicit account rather than the store's current one.
    private func syncJournal(_ db: SQLiteConnection, account: String, id: UUID, operation: SyncOperation, revision: Int) throws {
        try db.run("""
        INSERT INTO sync_outbox (account, record_id, op, revision, retry_id, created_at) VALUES (?, ?, ?, ?, ?, ?)
        """, [.text(account), .uuid(id), .text(operation.rawValue), .int(Int64(revision)), .uuid(makeID()), .date(now())])
    }
}
