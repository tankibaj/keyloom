import Foundation
import SQLite3

/// Opens the database file and brings it to the newest schema without risking the user's library.
///
/// Order, each step guarding the next:
/// 1. The migration list must be 1...n. Nothing is touched if it is not.
/// 2. A probe connection reads `user_version` before any statement writes to the file. A newer version
///    than this build knows throws `databaseNewerThanApp`; tables with no version throw
///    `unrecognizedDatabase`. Neither modifies the file (nor creates a WAL or backup next to it).
/// 3. A database that holds data is copied to `backupDirectory` and the copy verified before the first
///    step runs. No verified backup, no migration.
/// 4. Each step and its `user_version` bump commit in one transaction. If any step throws, the backup is
///    restored over the file, so a half-migrated database is never left behind, and the error is typed.
enum DatabaseMigrator {
    static let backupLabel = "pre-migration"

    static func open(at url: URL, migrations: [Migration], backupDirectory: URL, now: Date) throws -> SQLiteConnection {
        guard migrations.enumerated().allSatisfy({ $0.element.version == $0.offset + 1 }) else {
            throw StoreError.invalidMigrationPlan
        }
        let target = migrations.count
        let (version, hasObjects) = try inspect(url)
        if version > target { throw StoreError.databaseNewerThanApp(found: version, supported: target) }
        if version == 0, hasObjects { throw StoreError.unrecognizedDatabase }

        // Owner-only from creation, so there is no window with default permissions.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let database = try SQLiteConnection(path: url.path)
        guard try database.first("PRAGMA journal_mode = WAL", map: { $0.string(0) }) == "wal" else {
            throw StoreError.sqlite(code: SQLITE_ERROR, context: "journal_mode")
        }
        guard version < target else { return database }

        var backup: URL?
        if version > 0 {
            backup = try DatabaseBackup.write(database, to: backupDirectory, label: backupLabel, now: now)
        }
        var failedVersion = version
        do {
            for migration in migrations where migration.version > version {
                failedVersion = migration.version
                try database.transaction {
                    try migration.apply(database)
                    try database.setUserVersion(migration.version)
                }
            }
            return database
        } catch {
            database.close() // before the file is overwritten
            let restored = backup.map { DatabaseBackup.restore(from: $0, to: url, version: version) } ?? false
            throw StoreError.migrationFailed(failedVersion: failedVersion, restored: restored, backupPath: backup?.path)
        }
    }

    /// `user_version` and whether the file has any schema objects, read without writing. A missing or
    /// empty file is a new database.
    private static func inspect(_ url: URL) throws -> (version: Int, hasObjects: Bool) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size, size > 0 else { return (0, false) }
        let probe = try SQLiteConnection(path: url.path, createIfMissing: false)
        let objects = try probe.first("SELECT count(*) FROM sqlite_master") { $0.int(0) } ?? 0
        return (try probe.userVersion, objects > 0)
    }
}
