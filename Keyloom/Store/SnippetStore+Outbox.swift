import Foundation

enum SyncOperation: String, Sendable {
    case upsert, delete
}

/// One durable sync intent. A sync engine pushes `recordID` at `revision` (or its deletion), then
/// `acknowledge`s `retryID`; on failure it calls `markFailed` and reuses the same `retryID` next time.
/// Intents are append-only, so several can exist for one record: the engine pushes the latest state.
/// An upsert for a record purged since is a delete in effect, and its snippet is simply gone.
struct OutboxEntry: Sendable, Equatable, Identifiable {
    var id: UUID { retryID }
    let sequence: Int64
    let account: String
    let recordID: UUID
    let operation: SyncOperation
    let revision: Int
    let retryID: UUID
    let attempts: Int
    let createdAt: Date
    let lastAttemptAt: Date?
}

/// The durable queue. There is no sync engine here: entries are appended implicitly by each local
/// mutation (same transaction), and `pending` / `acknowledge` / `markFailed` are all a consumer needs.
/// Every call is scoped to one account (default: the store's current one); a row of another account is
/// never returned and never changed.
extension SnippetStore {
    static let maxAccountBytes = 256

    static func validateAccount(_ account: String) throws {
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              account.utf8.count <= maxAccountBytes else { throw StoreError.invalidAccount }
    }

    /// Switches which account new intents are journaled under (the iCloud account changed or sync was
    /// turned on for another one). Existing intents stay with their account.
    func setSyncAccount(_ account: String) throws {
        try Self.validateAccount(account)
        syncAccount = account
    }

    /// Oldest first, at most `limit`.
    func pending(account: String? = nil, limit: Int = 100) throws -> [OutboxEntry] {
        let scope = account ?? syncAccount
        return try read { db in
            try db.rows("""
            SELECT seq, account, record_id, op, revision, retry_id, attempts, created_at, last_attempt_at
            FROM sync_outbox WHERE account = ? ORDER BY seq LIMIT ?
            """, [.text(scope), .int(Int64(max(limit, 0)))]) { row in
                guard let recordID = UUID(uuidString: row.string(2)), let retryID = UUID(uuidString: row.string(5)),
                      let operation = SyncOperation(rawValue: row.string(3)) else {
                    throw StoreError.corruptRecord(column: "sync_outbox")
                }
                return OutboxEntry(sequence: Int64(row.int(0)), account: row.string(1), recordID: recordID,
                                   operation: operation, revision: row.int(4), retryID: retryID, attempts: row.int(6),
                                   createdAt: row.date(7), lastAttemptAt: row.isNull(8) ? nil : row.date(8))
            }
        }
    }

    /// Removes a pushed intent. False when no such row exists for the account.
    @discardableResult
    func acknowledge(retryID: UUID, account: String? = nil) throws -> Bool {
        let scope = account ?? syncAccount
        return try write { db in
            try db.run("DELETE FROM sync_outbox WHERE retry_id = ? AND account = ?", [.uuid(retryID), .text(scope)]) == 1
        }
    }

    /// Counts a failed push and keeps the intent, with the same `retryID`. False when no such row exists.
    @discardableResult
    func markFailed(retryID: UUID, account: String? = nil) throws -> Bool {
        let scope = account ?? syncAccount
        return try write { db in
            try db.run("""
            UPDATE sync_outbox SET attempts = attempts + 1, last_attempt_at = ? WHERE retry_id = ? AND account = ?
            """, [.date(now()), .uuid(retryID), .text(scope)]) == 1
        }
    }

    /// Appends the intent for a mutation. Must run inside the mutation's own transaction.
    func journal(_ db: SQLiteConnection, id: UUID, operation: SyncOperation, revision: Int) throws {
        try db.run("""
        INSERT INTO sync_outbox (account, record_id, op, revision, retry_id, created_at) VALUES (?, ?, ?, ?, ?, ?)
        """, [.text(syncAccount), .uuid(id), .text(operation.rawValue), .int(Int64(revision)), .uuid(makeID()),
              .date(now())])
    }
}
