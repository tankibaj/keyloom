import Foundation

/// Writes and restores whole-database copies with the SQLite online backup API, so a copy is a consistent
/// snapshot even when recent commits still sit in the WAL.
enum DatabaseBackup {
    /// `keyloom-<label>-v<schema version>-<unix seconds>.sqlite`, with `-2`, `-3`, ... when taken twice in
    /// a second. Never overwrites. The label is reduced to letters, digits and `-`, so it cannot steer the
    /// file out of `directory`. The file is written under a `.partial` name and renamed once verified, so a
    /// crash or failure never leaves a plausible-looking truncated backup.
    static func write(_ source: SQLiteConnection, to directory: URL, label: String, now: Date) throws -> URL {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.backupFailed(context: "directory")
        }
        let version: Int
        do { version = try source.userVersion } catch { throw StoreError.backupFailed(context: "version") }

        let safeLabel = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        let base = "keyloom-\(safeLabel.isEmpty ? "snapshot" : safeLabel)-v\(version)-\(Int(now.timeIntervalSince1970))"
        var final = directory.appendingPathComponent(base + ".sqlite")
        var suffix = 2
        while manager.fileExists(atPath: final.path) {
            final = directory.appendingPathComponent("\(base)-\(suffix).sqlite")
            suffix += 1
        }
        let partial = final.appendingPathExtension("partial")
        try? manager.removeItem(at: partial)
        // Owner-only from the first byte: snippets can hold sensitive text.
        guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.backupFailed(context: "create")
        }
        do {
            let destination = try SQLiteConnection(path: partial.path)
            defer { destination.close() } // the last connection closing removes -wal and -shm
            try source.copy(into: destination)
            try verify(destination, version: version)
            // A single self-contained file: nothing beside it to lose when it is moved.
            guard try destination.first("PRAGMA journal_mode = DELETE", map: { $0.string(0) }) == "delete" else {
                throw StoreError.backupFailed(context: "journal")
            }
            destination.close()
            // Leaving WAL mode strands an empty wal-index file; a surviving -wal would mean unmerged data.
            try? manager.removeItem(atPath: partial.path + "-shm")
            guard !manager.fileExists(atPath: partial.path + "-wal") else { throw StoreError.backupFailed(context: "journal") }
            try manager.moveItem(at: partial, to: final)
        } catch {
            for leftover in ["", "-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: partial.path + leftover) }
            throw StoreError.backupFailed(context: "write")
        }
        return final
    }

    /// Puts `backup` back over the database at `databaseURL`. Returns whether the result verified as the
    /// backup's schema version. Used only after a failed migration, when the live connection is closed.
    static func restore(from backup: URL, to databaseURL: URL, version: Int) -> Bool {
        do {
            let source = try SQLiteConnection(path: backup.path, createIfMissing: false)
            let destination = try SQLiteConnection(path: databaseURL.path)
            try source.copy(into: destination)
            try verify(destination, version: version)
            return true
        } catch {
            return false
        }
    }

    private static func verify(_ database: SQLiteConnection, version: Int) throws {
        guard try database.first("PRAGMA quick_check", map: { $0.string(0) }) == "ok", try database.userVersion == version else {
            throw StoreError.backupFailed(context: "verify")
        }
    }
}
