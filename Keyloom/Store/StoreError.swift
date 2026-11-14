import Foundation

/// Typed failures of the local store. Payloads are IDs, counts and SQLite result codes, never snippet
/// text, keywords or SQL, so an error is always safe to log.
enum StoreError: Error, Equatable, Sendable {
    case closed
    case notFound(id: UUID)
    case alreadyExists(id: UUID)
    /// Restore or purge of a snippet that is not in the trash.
    case notDeleted(id: UUID)
    /// Another enabled, live snippet already owns the keyword.
    case keywordConflict(existingID: UUID)
    case corruptRecord(column: String)
    case sqlite(code: Int32, context: String)
    case invalidAccount
    /// The file's `user_version` is above what this build knows. The file is left exactly as found.
    case databaseNewerThanApp(found: Int, supported: Int)
    /// A file with tables but no `user_version`: not ours, so it is never migrated.
    case unrecognizedDatabase
    case invalidMigrationPlan
    /// A step failed. `restored` says whether the pre-migration backup was put back and verified;
    /// `backupPath` is that backup, kept either way. Both are nil/false for a database that was new.
    case migrationFailed(failedVersion: Int, restored: Bool, backupPath: String?)
    /// A backup could not be written or did not verify. `context` is a fixed label, never a path or text.
    case backupFailed(context: String)
}

extension StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .closed: "The snippet library is closed."
        case .notFound: "The snippet does not exist."
        case .alreadyExists: "A snippet with this ID already exists."
        case .notDeleted: "The snippet is not in the trash."
        case .keywordConflict: "Another enabled snippet already uses this keyword."
        case .corruptRecord(let column): "A stored snippet has an unreadable \(column) value."
        case .sqlite(let code, let context): "The snippet library failed (\(context), SQLite code \(code))."
        case .invalidAccount: "The sync account identifier is empty or too long."
        case .databaseNewerThanApp(let found, let supported):
            "This library was written by a newer Keyloom (schema \(found); this version reads up to \(supported)). "
                + "Update Keyloom, or restore a backup made by this version. The file was not changed."
        case .unrecognizedDatabase: "This file is not a Keyloom library and was not changed."
        case .invalidMigrationPlan: "The schema migration list is not a contiguous sequence starting at 1."
        case .migrationFailed(let version, let restored, let backupPath):
            if restored { "Upgrading the library to schema \(version) failed; your previous library was restored from a backup." }
            else if backupPath != nil { "Upgrading the library to schema \(version) failed and could not be rolled back; the backup was kept." }
            else { "Setting up the library at schema \(version) failed." }
        case .backupFailed(let context): "Writing a library backup failed (\(context)); nothing was changed."
        }
    }
}
