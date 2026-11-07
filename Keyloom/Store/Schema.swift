import Foundation

/// One forward step of the schema. `version` is the `PRAGMA user_version` the database has after it ran.
/// The runner applies each step inside its own transaction and bumps `user_version` in the same one.
struct Migration: Sendable {
    let version: Int
    let apply: @Sendable (SQLiteConnection) throws -> Void
}

/// Shipped migrations are immutable: change the schema only by appending a step. A frozen v1 fixture in
/// the tests guards this.
///
/// Rollback (there are no down-migrations, by design): before any step runs on a database that holds
/// data, the runner copies it to the caller's backup directory, and if a step fails it restores that
/// copy. To undo a step that already shipped, restore the pre-migration backup the runner wrote and run
/// the previous app version; a step that cannot be undone that way must say so in its own comment.
enum Migrations {
    static let all: [Migration] = [v1, v2]

    /// Initial schema.
    /// Down note: v1 only creates objects, so there is nothing to revert but the whole file. Rolling back
    /// means deleting the database (a fresh install) or restoring a backup.
    static let v1 = Migration(version: 1) { database in
        try database.execute(schemaV1)
    }

    private static let schemaV1 = """
    CREATE TABLE snippets (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        icon_kind TEXT NOT NULL CHECK (icon_kind IN ('emoji', 'symbol')),
        icon_value TEXT NOT NULL,
        keyword TEXT CHECK (keyword IS NULL OR length(keyword) > 0),
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
        revision INTEGER NOT NULL CHECK (revision >= 1),
        template BLOB NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        last_used_at REAL,
        use_count INTEGER NOT NULL DEFAULT 0 CHECK (use_count >= 0),
        deleted_at REAL
    ) STRICT;

    CREATE UNIQUE INDEX snippets_enabled_keyword ON snippets (keyword)
        WHERE enabled = 1 AND keyword IS NOT NULL AND deleted_at IS NULL;
    CREATE INDEX snippets_last_used ON snippets (last_used_at)
        WHERE deleted_at IS NULL AND last_used_at IS NOT NULL;
    CREATE INDEX snippets_deleted ON snippets (deleted_at) WHERE deleted_at IS NOT NULL;

    CREATE TABLE snippet_tags (
        snippet_id TEXT NOT NULL REFERENCES snippets (id) ON DELETE CASCADE,
        tag TEXT NOT NULL CHECK (length(tag) > 0),
        position INTEGER NOT NULL,
        PRIMARY KEY (snippet_id, tag)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX snippet_tags_tag ON snippet_tags (tag);

    CREATE TABLE snippet_revisions (
        snippet_id TEXT NOT NULL REFERENCES snippets (id) ON DELETE CASCADE,
        revision INTEGER NOT NULL,
        recorded_at REAL NOT NULL,
        snapshot BLOB NOT NULL,
        PRIMARY KEY (snippet_id, revision)
    ) STRICT, WITHOUT ROWID;

    -- Durable sync intent, appended in the same transaction as the mutation it describes. `account` keeps
    -- one iCloud account's queue from ever being replayed for another; `retry_id` is the stable identity
    -- a sync engine reuses across retries. No foreign key: a delete intent must outlive a purged row.
    CREATE TABLE sync_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        account TEXT NOT NULL CHECK (length(account) > 0),
        record_id TEXT NOT NULL,
        op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
        revision INTEGER NOT NULL,
        retry_id TEXT NOT NULL UNIQUE,
        attempts INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        last_attempt_at REAL
    ) STRICT;
    CREATE INDEX sync_outbox_account_seq ON sync_outbox (account, seq);
    """
}
