import Darwin
import Foundation

/// Local, atomic library snapshots in one directory.
///
/// - A snapshot is the native snippet JSON plus a kind, a creation time and a content fingerprint, in a file
///   named `keyloom-<kind>-<unix seconds>-<sequence>.keyloomsnap`. Listing reads names only.
/// - Writes go to `<name>.partial` (owner-only), are fsynced, then renamed into place, so a crash or failure
///   never leaves something that looks like a snapshot. Leftover `.partial` files are removed on the next write.
/// - `takeDailyIfChanged` writes at most one `daily` snapshot per calendar day and only when the library's
///   fingerprint differs from the newest daily one. A failed attempt does not use up the day.
/// - Retention, applied after each write: the newest 30 daily snapshots, and the newest 10 `preImport` and
///   `preRestore` snapshots together. Pruning is best effort: a file that cannot be removed is retried on the
///   next write and never fails the snapshot that was just taken.
/// - `load` validates before anything can use a snapshot: size, format name and version, every snippet, unique
///   ids and the fingerprint. A bad file throws a `SnapshotError`; nothing else is touched.
/// - Snapshots hold snippet text: owner-only files, and the content is never logged or put into an error.
actor SnapshotManager {
    static let dailyRetention = 30
    static let safeguardRetention = 10
    static let maxSnapshotBytes = 128 * 1_048_576
    static let formatName = "keyloom-snapshot"
    static let currentVersion = 1

    private static let fileExtension = "keyloomsnap"
    private static let namePrefix = "keyloom-"

    nonisolated let directory: URL
    /// Pass this as the `SnippetStore` backup directory so the store's automatic pre-migration copies land beside
    /// the snapshots (`preMigrationBackup(of:)` writes there too). Not subject to snapshot retention.
    nonisolated let migrationBackupDirectory: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let beforePublish: @Sendable () throws -> Void

    /// `beforePublish` runs after the temporary file is complete and before it is renamed into place: the
    /// seam tests use to simulate a crash at the worst moment.
    init(directory: URL, now: @escaping @Sendable () -> Date, calendar: Calendar = .current,
         beforePublish: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory
        migrationBackupDirectory = directory.appendingPathComponent("migrations", isDirectory: true)
        self.now = now
        self.calendar = calendar
        self.beforePublish = beforePublish
    }

    // MARK: Taking snapshots

    /// The daily snapshot, or nil when today already has one or nothing changed since the last one.
    func takeDailyIfChanged(_ snippets: [Snippet]) throws -> SnapshotInfo? {
        let fingerprint = try SnapshotFingerprint.of(snippets)
        if let newest = try list().first(where: { $0.kind == .daily }) {
            if calendar.isDate(newest.createdAt, inSameDayAs: now()) { return nil }
            // An unreadable last snapshot must not stop the next one: treat it as "changed".
            if let last = try? storedFingerprint(of: newest), last == fingerprint { return nil }
        }
        return try write(.daily, snippets, fingerprint: fingerprint)
    }

    /// Always writes: the copy to fall back on before an import or a restore.
    func takeSafeguard(_ kind: SnapshotKind, snippets: [Snippet]) throws -> SnapshotInfo {
        precondition(kind != .daily, "daily snapshots go through takeDailyIfChanged")
        return try write(kind, snippets, fingerprint: try SnapshotFingerprint.of(snippets))
    }

    /// Pre-migration safeguard: the store's own verified SQLite copy, kept in `migrationBackupDirectory`.
    /// TODO(keyloom-wp5): migration copies are not pruned (a schema change is rare); add retention if schema
    /// changes become frequent.
    func preMigrationBackup(of store: SnippetStore) async throws -> URL {
        try await store.backup(to: migrationBackupDirectory, label: DatabaseMigrator.backupLabel)
    }

    // MARK: Listing and loading

    /// Newest first. A missing directory is an empty list.
    func list() throws -> [SnapshotInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap(info(named:)).sorted { ($0.createdAt, $0.sequence) > ($1.createdAt, $1.sequence) }
    }

    func load(_ info: SnapshotInfo) throws -> SnapshotContents {
        guard let data = try? Data(contentsOf: info.url) else { throw SnapshotError.unreadable }
        guard data.count <= Self.maxSnapshotBytes else { throw SnapshotError.corrupt }
        let decoder = Self.decoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == Self.formatName else {
            throw SnapshotError.corrupt
        }
        guard header.formatVersion <= Self.currentVersion else {
            throw SnapshotError.unsupportedVersion(found: header.formatVersion, supported: Self.currentVersion)
        }
        let file: StoredFile
        do {
            file = try decoder.decode(StoredFile.self, from: data)
            for snippet in file.snippets { try SnippetStore.validate(snippet) }
        } catch KeyloomError.unsupportedSchemaVersion(let found, let supported) {
            throw SnapshotError.unsupportedVersion(found: found, supported: supported)
        } catch {
            throw SnapshotError.corrupt
        }
        guard Set(file.snippets.map(\.id)).count == file.snippets.count,
              (try? SnapshotFingerprint.of(file.snippets)) == file.fingerprint else { throw SnapshotError.corrupt }
        return SnapshotContents(info: info, snippets: file.snippets)
    }

    // MARK: File format

    private struct Header: Decodable {
        let format: String
        let formatVersion: Int
    }

    private struct FingerprintOnly: Decodable {
        let fingerprint: String
    }

    private struct StoredFile: Codable {
        var format = SnapshotManager.formatName
        var formatVersion = SnapshotManager.currentVersion
        let kind: String
        let createdAt: Date
        let fingerprint: String
        let snippets: [Snippet]
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func storedFingerprint(of info: SnapshotInfo) throws -> String {
        try Self.decoder().decode(FingerprintOnly.self, from: Data(contentsOf: info.url)).fingerprint
    }

    // MARK: Writing

    private func write(_ kind: SnapshotKind, _ snippets: [Snippet], fingerprint: String) throws -> SnapshotInfo {
        let moment = now()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw SnapshotError.writeFailed(context: "directory")
        }
        removeStalePartials()

        let seconds = Int(moment.timeIntervalSince1970.rounded(.down))
        let sequence = ((try? list()) ?? []).filter { Int($0.createdAt.timeIntervalSince1970) == seconds }.map(\.sequence).max().map { $0 + 1 } ?? 1
        let final = directory.appendingPathComponent("\(Self.namePrefix)\(kind.rawValue)-\(seconds)-\(sequence).\(Self.fileExtension)")
        let partial = final.appendingPathExtension("partial")
        let info = SnapshotInfo(url: final, kind: kind, createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)), sequence: sequence)

        do {
            var stored = snippets
            for index in stored.indices { stored[index].lastUsedAt = nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(StoredFile(kind: kind.rawValue, createdAt: info.createdAt, fingerprint: fingerprint, snippets: stored))

            // Owner-only from the first byte.
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SnapshotError.writeFailed(context: "write")
            }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            Self.flushToDisk(handle.fileDescriptor)
            try beforePublish()
            guard rename(partial.path, final.path) == 0 else { throw SnapshotError.writeFailed(context: "write") }
        } catch {
            try? manager.removeItem(at: partial)
            throw SnapshotError.writeFailed(context: "write")
        }
        Self.syncDirectory(directory)
        prune()
        return info
    }

    /// Full fsync where the filesystem supports it, so the bytes are on disk before the rename publishes them.
    private static func flushToDisk(_ descriptor: Int32) {
        if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
    }

    /// Makes the rename itself durable. Best effort: the snapshot is already complete and visible.
    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        flushToDisk(descriptor)
        close(descriptor)
    }

    private func removeStalePartials() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".\(Self.fileExtension).partial") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func prune() {
        guard let snapshots = try? list() else { return }
        let daily = snapshots.filter { $0.kind == .daily }
        let safeguards = snapshots.filter { $0.kind != .daily }
        for expired in daily.dropFirst(Self.dailyRetention) + safeguards.dropFirst(Self.safeguardRetention) {
            try? FileManager.default.removeItem(at: expired.url)
        }
    }

    /// `keyloom-<kind>-<seconds>-<sequence>.keyloomsnap`; anything else in the directory is not ours.
    private func info(named name: String) -> SnapshotInfo? {
        guard name.hasPrefix(Self.namePrefix), name.hasSuffix(".\(Self.fileExtension)") else { return nil }
        let stem = name.dropFirst(Self.namePrefix.count).dropLast(Self.fileExtension.count + 1)
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = SnapshotKind(rawValue: String(parts[0])),
              let seconds = Int(parts[1]), let sequence = Int(parts[2]) else { return nil }
        return SnapshotInfo(url: directory.appendingPathComponent(name), kind: kind,
                            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)), sequence: sequence)
    }
}
