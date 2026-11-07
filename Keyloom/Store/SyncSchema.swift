extension Migrations {
    /// Per-account sync bookkeeping. Both tables are keyed by account, so one iCloud account's ancestors and
    /// engine state are never read or written for another.
    ///
    /// Down note: v2 only adds two tables. The runner backs the database up before this step and restores
    /// that copy if it fails; to undo it after it shipped, restore the pre-migration backup and run the
    /// previous app version (an older build refuses a newer `user_version`, so dropping the tables by hand is
    /// not enough). Nothing in v1 changes, and the v1 library data is untouched either way.
    static let v2 = Migration(version: 2) { database in
        try database.execute(schemaV2)
    }

    private static let schemaV2 = """
    -- The agreed ancestor of each record per account: `snapshot` is the Snippet JSON last pulled or pushed
    -- (NULL when the agreed state is a deletion), `system_fields` the server's opaque version tag. No foreign
    -- key: a deletion ancestor must outlive a purged row.
    CREATE TABLE sync_records (
        account TEXT NOT NULL CHECK (length(account) > 0),
        record_id TEXT NOT NULL,
        snapshot BLOB,
        system_fields BLOB,
        PRIMARY KEY (account, record_id)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX sync_records_record ON sync_records (record_id);

    -- The sync engine's serialized state (change token, pending list) per account.
    CREATE TABLE sync_engine_state (
        account TEXT NOT NULL PRIMARY KEY CHECK (length(account) > 0),
        state BLOB NOT NULL
    ) STRICT, WITHOUT ROWID;
    """
}

extension Migrations {
    /// Marks snippets that sync turned off because another snippet holds their keyword, so that forced state is
    /// never pushed to iCloud as if the user had chosen it.
    /// Down note: v3 only adds one table; undo it by restoring the pre-migration backup the runner writes.
    static let v3 = Migration(version: 3) { database in
        try database.execute("""
        CREATE TABLE sync_conflict_disabled (
            record_id TEXT NOT NULL PRIMARY KEY
        ) STRICT, WITHOUT ROWID;
        """)
    }
}

extension Migrations {
    /// Remembers the revision at which sync turned a snippet off, so a later edit that enabled it is detected and
    /// its marker dropped. Existing (v3) markers are backfilled with the snippet's current revision while it is
    /// still disabled (an edit that left it disabled does not matter), so a forced disable stays recognized; a marker
    /// whose snippet was enabled, deleted or purged since gets 0, which never matches, and is dropped as stale.
    /// Down note: v4 adds one column; undo it by restoring the pre-migration backup.
    static let v4 = Migration(version: 4) { database in
        try database.execute("""
        ALTER TABLE sync_conflict_disabled ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
        UPDATE sync_conflict_disabled SET revision = COALESCE(
            (SELECT s.revision FROM snippets s WHERE s.id = sync_conflict_disabled.record_id
             AND s.enabled = 0 AND s.deleted_at IS NULL), 0);
        """)
    }
}
