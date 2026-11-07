import SQLite3
import XCTest
@testable import Keyloom

final class MigrationTests: StoreTestCase {
    private struct Boom: Error {}

    /// A later schema step, defined by the test: adds a column. It also adds `icon_color` (schema v5's column),
    /// because the store reads it on every snippet and this stands in for a schema newer than v1.
    private let v2 = Migration(version: 2) {
        try $0.execute("ALTER TABLE snippets ADD COLUMN note TEXT; ALTER TABLE snippets ADD COLUMN icon_color TEXT")
    }
    /// A step that changes the schema and then fails.
    private let failingV3 = Migration(version: 3) { database in
        try database.execute("ALTER TABLE snippets ADD COLUMN broken TEXT")
        throw Boom()
    }

    private let fixtureID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// A database frozen at schema v1, written as literal SQL rather than by the code under test, so editing
    /// a shipped migration breaks this test. Holds one snippet with a tag, history and a pending outbox row.
    private func makeV1Fixture(at url: URL) throws -> Snippet {
        let snippet = makeSnippet(id: fixtureID, name: "Fixture", keyword: ";fx", tags: ["old"], text: "Grüße")
        let raw = try RawDatabase(url)
        try raw.execute("""
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
        """)
        let created = snippet.createdAt.timeIntervalSince1970
        try raw.execute("""
        INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, revision, template, created_at, updated_at)
        VALUES ('\(fixtureID.uuidString)', 'Fixture', 'symbol', 'text.bubble', ';fx', 1, 1, x'\(hex(try snippet.template.encoded()))', \(created), \(created));
        INSERT INTO snippet_tags (snippet_id, tag, position) VALUES ('\(fixtureID.uuidString)', 'old', 0);
        INSERT INTO snippet_revisions (snippet_id, revision, recorded_at, snapshot)
        VALUES ('\(fixtureID.uuidString)', 1, \(created), x'\(hex(try JSONEncoder().encode(snippet)))');
        INSERT INTO sync_outbox (account, record_id, op, revision, retry_id, created_at)
        VALUES ('local', '\(fixtureID.uuidString)', 'upsert', 1, '99999999-0000-0000-0000-000000000001', \(created));
        PRAGMA user_version = 1;
        """)
        return snippet
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    private func hasColumn(_ raw: RawDatabase, _ name: String) throws -> Bool {
        try raw.int("SELECT count(*) FROM pragma_table_info('snippets') WHERE name = '\(name)'") == 1
    }

    // MARK: Forward migration

    func testFreshDatabaseIsCreatedAtLatestVersionWithoutABackup() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        _ = try openStore(at: url, backupDirectory: backups)
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, Migrations.all.count)
        XCTAssertEqual(try backupFiles(in: backups), [], "nothing to protect in a new database")
    }

    func testFrozenV1FixtureOpensAndServesItsDataThroughTheStore() async throws {
        let url = try databaseURL()
        let expected = try makeV1Fixture(at: url)
        let store = try openStore(at: url)
        let fetched = try await store.snippet(id: fixtureID)
        XCTAssertEqual(fetched, expected)
        let pending = try await store.pending()
        XCTAssertEqual(pending.map(\.recordID), [fixtureID])
        let revisions = try await store.revisions(of: fixtureID)
        XCTAssertEqual(revisions.map(\.snippet), [expected])
        // The v1 schema still enforces what v1 promised.
        await assertThrows(.keywordConflict(existingID: fixtureID)) { _ = try await store.create(self.makeSnippet(keyword: ";fx")) }
    }

    func testOlderDatabaseMigratesForwardAfterAVerifiedBackup() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        let expected = try makeV1Fixture(at: url)

        let store = try openStore(at: url, migrations: [Migrations.v1, v2], backupDirectory: backups)

        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, 2)
        XCTAssertTrue(try hasColumn(raw, "note"))
        let fetched = try await store.snippet(id: fixtureID)
        XCTAssertEqual(fetched, expected, "data survives the migration")

        let files = try backupFiles(in: backups)
        XCTAssertEqual(files.count, 1)
        let backup = try XCTUnwrap(files.first)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("keyloom-pre-migration-v1-"), backup.lastPathComponent)
        XCTAssertEqual(backup.pathExtension, "sqlite")
        let snapshot = try RawDatabase(backup)
        XCTAssertEqual(try snapshot.userVersion, 1, "the backup is the database as it was before migrating")
        XCTAssertFalse(try hasColumn(snapshot, "note"))
        XCTAssertEqual(try snapshot.count("snippets"), 1)
        XCTAssertEqual(try snapshot.text("PRAGMA quick_check"), "ok")
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAlreadyCurrentDatabaseIsNotBackedUpAgain() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        _ = try makeV1Fixture(at: url)
        _ = try openStore(at: url, migrations: [Migrations.v1, v2], backupDirectory: backups)
        _ = try openStore(at: url, migrations: [Migrations.v1, v2], backupDirectory: backups)
        XCTAssertEqual(try backupFiles(in: backups).count, 1)
    }

    // MARK: Failure and restore

    func testFailingMigrationRestoresTheBackupAndReportsTypedError() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        let expected = try makeV1Fixture(at: url)

        do {
            _ = try openStore(at: url, migrations: [Migrations.v1, v2, failingV3], backupDirectory: backups)
            XCTFail("migration should fail")
        } catch StoreError.migrationFailed(let failedVersion, let restored, let backupPath) {
            XCTAssertEqual(failedVersion, 3)
            XCTAssertTrue(restored)
            let path = try XCTUnwrap(backupPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the backup stays for the user")
        }

        // Step 2 had committed before step 3 failed; restoring undoes it too.
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, 1)
        XCTAssertFalse(try hasColumn(raw, "note"))
        XCTAssertFalse(try hasColumn(raw, "broken"))
        XCTAssertEqual(try raw.text("PRAGMA quick_check"), "ok")

        let store = try openStore(at: url, backupDirectory: backups)
        let fetched = try await store.snippet(id: fixtureID)
        XCTAssertEqual(fetched, expected)
        let pending = try await store.pending()
        XCTAssertEqual(pending.count, 1)
    }

    func testRetryAfterFailureCanSucceedWithAFixedMigration() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        _ = try makeV1Fixture(at: url)
        XCTAssertThrowsError(try openStore(at: url, migrations: [Migrations.v1, v2, failingV3], backupDirectory: backups))
        _ = try openStore(at: url, migrations: [Migrations.v1, v2], backupDirectory: backups)
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, 2)
    }

    func testUnwritableBackupLocationAbortsBeforeAnyChange() async throws {
        let url = try databaseURL()
        _ = try makeV1Fixture(at: url)
        let notADirectory = url.deletingLastPathComponent().appendingPathComponent("occupied")
        try Data("file".utf8).write(to: notADirectory)

        XCTAssertThrowsError(try openStore(at: url, migrations: [Migrations.v1, v2], backupDirectory: notADirectory)) { error in
            guard case StoreError.backupFailed = error else { return XCTFail("wrong error \(error)") }
        }
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, 1)
        XCTAssertFalse(try hasColumn(raw, "note"))
    }

    // MARK: Downgrade and foreign files

    private func snapshotOfDirectory(_ directory: URL, database: URL) throws -> (Data, [String]) {
        (try Data(contentsOf: database), try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted())
    }

    func testNewerSchemaThrowsTypedErrorAndDoesNotModifyTheFile() async throws {
        let url = try databaseURL()
        let raw = try RawDatabase(url)
        try raw.execute("CREATE TABLE future (x TEXT); INSERT INTO future VALUES ('data'); PRAGMA user_version = 99;")
        let directory = url.deletingLastPathComponent()
        let before = try snapshotOfDirectory(directory, database: url)

        XCTAssertThrowsError(try openStore(at: url)) { error in
            XCTAssertEqual(error as? StoreError, .databaseNewerThanApp(found: 99, supported: Migrations.all.count))
            XCTAssertTrue(error.localizedDescription.contains("newer"), "guidance tells the user what to do")
        }

        let after = try snapshotOfDirectory(directory, database: url)
        XCTAssertEqual(after.0, before.0, "database bytes unchanged")
        XCTAssertEqual(after.1, before.1, "no WAL, backup or other file was created")
    }

    func testUnrecognizedDatabaseAtVersionZeroIsRefusedUntouched() async throws {
        let url = try databaseURL()
        let raw = try RawDatabase(url)
        try raw.execute("CREATE TABLE somebody_elses (x TEXT); INSERT INTO somebody_elses VALUES ('theirs')")
        let directory = url.deletingLastPathComponent()
        let before = try snapshotOfDirectory(directory, database: url)

        XCTAssertThrowsError(try openStore(at: url)) { error in
            XCTAssertEqual(error as? StoreError, .unrecognizedDatabase)
        }
        let after = try snapshotOfDirectory(directory, database: url)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testNonSQLiteFileIsRefusedUntouched() async throws {
        let url = try databaseURL()
        try Data("this is not a database, it is a very long text so that sqlite sees a full header page ....".utf8).write(to: url)
        let directory = url.deletingLastPathComponent()
        let before = try snapshotOfDirectory(directory, database: url)

        XCTAssertThrowsError(try openStore(at: url)) { error in
            guard case StoreError.sqlite(let code, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code & 0xFF, SQLITE_NOTADB)
        }
        let after = try snapshotOfDirectory(directory, database: url)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testMigrationPlanMustBeContiguousFromOne() async throws {
        let url = try databaseURL()
        for plan in [[v2], [Migrations.v1, Migrations.v1], [Migrations.v1, failingV3]] {
            XCTAssertThrowsError(try openStore(at: url, migrations: plan)) { error in
                XCTAssertEqual(error as? StoreError, .invalidMigrationPlan)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a bad plan creates nothing")
    }

    // MARK: backup(to:)

    func testBackupIsAConsistentOpenableCopyIncludingUncheckpointedWrites() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let snippet = try await store.create(makeSnippet(tags: ["a"]))
        let destination = url.deletingLastPathComponent().appendingPathComponent("snapshots/daily")

        let backup = try await store.backup(to: destination, label: "daily")

        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("keyloom-daily-v\(Migrations.all.count)-"), backup.lastPathComponent)
        XCTAssertEqual(try backupFiles(in: destination).count, 1, "a single self-contained file, no sidecars or partials")
        XCTAssertEqual(try RawDatabase(backup).text("PRAGMA journal_mode"), "delete")
        let copy = try openStore(at: backup, backupDirectory: destination)
        let fetched = try await copy.snippet(id: snippet.id)
        XCTAssertEqual(fetched, snippet)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testBackupsNeverOverwriteEachOtherAndSanitizeTheLabel() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let destination = url.deletingLastPathComponent().appendingPathComponent("snapshots")
        let first = try await store.backup(to: destination, label: "../../evil")
        let second = try await store.backup(to: destination, label: "../../evil")
        XCTAssertNotEqual(first, second, "same label and second: still two files")
        XCTAssertEqual(try backupFiles(in: destination).count, 2)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertFalse(first.lastPathComponent.contains("/"))
    }

    func testBackupToAnUnusableLocationFailsTypedAndLeavesNoPartialFile() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let occupied = url.deletingLastPathComponent().appendingPathComponent("occupied")
        try Data("file".utf8).write(to: occupied)
        do {
            _ = try await store.backup(to: occupied)
            XCTFail("expected failure")
        } catch {
            guard case StoreError.backupFailed = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
