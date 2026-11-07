import Foundation
import SQLite3

/// The local snippet library. One actor owns one SQLite connection; every public method is a single
/// transaction, so a failure leaves no partial write. Snippet text, keywords and tags are only ever
/// bound as statement parameters, never logged, interpolated into SQL or put into an error.
///
/// Policies:
/// - Delete is a tombstone: the row stays (so undo works), its keyword is free for reuse and it is
///   hidden from every listing. Tombstones are purged for good after `tombstoneRetention`, by
///   `purgeExpiredTombstones()` (a caller runs it on launch) or by `purge(id:)`.
/// - The store owns `revision`: it is `previous + 1` on every content change, whatever the caller sent.
///   TODO(keyloom-wp5): writes are last-writer-wins; sync conflict copies arrive with the sync engine.
/// - Usage (`lastUsedAt`, use count) is device-local: it never bumps a revision, and `update` ignores a
///   caller's `lastUsedAt`.
/// - Revision history keeps the newest `maxRevisionsPerSnippet` snapshots per snippet.
///
/// Opening blocks on file I/O: create the store off the keyboard callback.
actor SnippetStore {
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
    static let maxRevisionsPerSnippet = 50

    private static let columns = """
    id, name, icon_kind, icon_value, keyword, enabled, pinned, revision, template, created_at, updated_at, \
    last_used_at, deleted_at
    """
    private static let defaultOrder = "pinned DESC, name COLLATE NOCASE, created_at, id"
    private static let uniqueConstraint = SQLITE_CONSTRAINT | (8 << 8)

    private var database: SQLiteConnection?
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    /// `now` and `makeID` are injected so tests control time and identifiers.
    init(url: URL, migrations: [Migration] = Migrations.all, now: @escaping @Sendable () -> Date = { Date() },
         makeID: @escaping @Sendable () -> UUID = { UUID() }) throws {
        self.now = now
        self.makeID = makeID
        database = try Self.openDatabase(at: url, migrations: migrations)
    }

    func close() { database = nil }

    // MARK: Create, read, update

    /// Stores `snippet` as given (so an import keeps its revision), except that usage starts empty.
    func create(_ snippet: Snippet) throws -> Snippet {
        try Self.validate(snippet)
        var stored = snippet
        stored.lastUsedAt = nil
        let template = try stored.template.encoded()
        return try write { db in
            if try db.first("SELECT 1 FROM snippets WHERE id = ?", [.uuid(stored.id)], map: { $0.int(0) }) != nil {
                throw StoreError.alreadyExists(id: stored.id)
            }
            try mappingKeywordConflict(db, id: stored.id, keyword: stored.keyword) {
                try db.run("""
                INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, pinned, revision, template,
                                      created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.uuid(stored.id), .text(stored.name)] + Self.iconValues(stored.icon) + [
                    .text(orNull: stored.keyword), .bool(stored.enabled), .bool(stored.pinned), .int(Int64(stored.revision)),
                    .blob(template), .date(stored.createdAt), .date(stored.updatedAt),
                ])
            }
            try replaceTags(db, of: stored)
            try recordRevision(db, stored)
            return stored
        }
    }

    /// A live snippet, or nil when unknown or in the trash.
    func snippet(id: UUID) throws -> Snippet? {
        try read { db in try load(db, where: "id = ? AND deleted_at IS NULL", [.uuid(id)]).first?.snippet }
    }

    /// Live snippets, pinned first, then by name. Optionally only those carrying `tag`.
    func allSnippets(tag: String? = nil) throws -> [Snippet] {
        try read { db in
            if let tag {
                return try load(db, where: "deleted_at IS NULL AND id IN (SELECT snippet_id FROM snippet_tags WHERE tag = ?)",
                                [.text(tag)]).map(\.snippet)
            }
            return try load(db, where: "deleted_at IS NULL").map(\.snippet)
        }
    }

    /// Saves every caller-owned field of a live snippet; `id` and `createdAt` never change.
    func update(_ snippet: Snippet) throws -> Snippet {
        try Self.validate(snippet)
        let template = try snippet.template.encoded()
        return try write { db in
            guard let current = try load(db, where: "id = ? AND deleted_at IS NULL", [.uuid(snippet.id)]).first?.snippet else {
                throw StoreError.notFound(id: snippet.id)
            }
            var stored = snippet
            stored.revision = current.revision + 1
            stored.createdAt = current.createdAt
            stored.updatedAt = now()
            stored.lastUsedAt = current.lastUsedAt
            try mappingKeywordConflict(db, id: stored.id, keyword: stored.keyword) {
                try db.run("""
                UPDATE snippets SET name = ?, icon_kind = ?, icon_value = ?, keyword = ?, enabled = ?, pinned = ?,
                                    revision = ?, template = ?, updated_at = ?
                WHERE id = ?
                """, [.text(stored.name)] + Self.iconValues(stored.icon) + [
                    .text(orNull: stored.keyword), .bool(stored.enabled), .bool(stored.pinned), .int(Int64(stored.revision)),
                    .blob(template), .date(stored.updatedAt), .uuid(stored.id),
                ])
            }
            try replaceTags(db, of: stored)
            try recordRevision(db, stored)
            return stored
        }
    }

    /// A copy with a new ID and " copy" appended to the name. A copy of an enabled keyword is created
    /// disabled, because two enabled snippets cannot share a keyword; the user resolves that by editing.
    func duplicate(id: UUID) throws -> Snippet {
        guard let original = try snippet(id: id) else { throw StoreError.notFound(id: id) }
        let moment = now()
        let copy = Snippet(id: makeID(), name: original.name + " copy", icon: original.icon, keyword: original.keyword,
                           enabled: original.enabled && original.keyword == nil, tags: original.tags,
                           template: original.template, createdAt: moment)
        return try create(copy)
    }

    func setPinned(_ pinned: Bool, id: UUID) throws -> Snippet {
        try write { db in
            try requireLive(db, id)
            try db.run("UPDATE snippets SET pinned = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
                       [.bool(pinned), .date(now()), .uuid(id)])
            return try reloadAndRecord(db, id)
        }
    }

    // MARK: Delete, undo, purge

    func delete(id: UUID) throws {
        try write { db in
            try requireLive(db, id)
            let moment = SQLValue.date(now())
            try db.run("UPDATE snippets SET deleted_at = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                       [moment, moment, .uuid(id)])
        }
    }

    func deletedSnippets() throws -> [DeletedSnippet] {
        try read { db in
            try load(db, where: "deleted_at IS NOT NULL", order: "deleted_at DESC, id").compactMap { loaded in
                loaded.deletedAt.map { DeletedSnippet(snippet: loaded.snippet, deletedAt: $0) }
            }
        }
    }

    /// Undo of `delete`. If another enabled snippet took the keyword meanwhile this throws
    /// `keywordConflict` and keeps the tombstone, unless `disablingOnKeywordConflict` restores it disabled.
    func restore(id: UUID, disablingOnKeywordConflict: Bool = false) throws -> Snippet {
        try write { db in
            guard let tombstone = try load(db, where: "id = ?", [.uuid(id)]).first else { throw StoreError.notFound(id: id) }
            guard tombstone.deletedAt != nil else { throw StoreError.notDeleted(id: id) }
            let moment = SQLValue.date(now())
            do {
                try mappingKeywordConflict(db, id: id, keyword: tombstone.snippet.keyword) {
                    try db.run("UPDATE snippets SET deleted_at = NULL, updated_at = ?, revision = revision + 1 WHERE id = ?",
                               [moment, .uuid(id)])
                }
            } catch StoreError.keywordConflict where disablingOnKeywordConflict {
                try db.run("UPDATE snippets SET deleted_at = NULL, enabled = 0, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           [moment, .uuid(id)])
            }
            return try reloadAndRecord(db, id)
        }
    }

    /// Permanently removes a snippet that is in the trash, with its tags and history.
    func purge(id: UUID) throws {
        try write { db in
            guard let tombstone = try load(db, where: "id = ?", [.uuid(id)]).first else { throw StoreError.notFound(id: id) }
            guard tombstone.deletedAt != nil else { throw StoreError.notDeleted(id: id) }
            try db.run("DELETE FROM snippets WHERE id = ?", [.uuid(id)])
        }
    }

    /// Purges tombstones older than `tombstoneRetention`; returns how many. Live snippets are never touched.
    @discardableResult
    func purgeExpiredTombstones() throws -> Int {
        try write { db in
            let cutoff = now().addingTimeInterval(-Self.tombstoneRetention)
            return try db.run("DELETE FROM snippets WHERE deleted_at IS NOT NULL AND deleted_at <= ?", [.date(cutoff)])
        }
    }

    // MARK: Usage

    func recordUsage(id: UUID) throws {
        try write { db in
            let changed = try db.run("""
            UPDATE snippets SET last_used_at = ?, use_count = use_count + 1 WHERE id = ? AND deleted_at IS NULL
            """, [.date(now()), .uuid(id)])
            if changed == 0 { throw StoreError.notFound(id: id) }
        }
    }

    func usage(of id: UUID) throws -> SnippetUsage {
        try read { db in
            let usage = try db.first("SELECT last_used_at, use_count FROM snippets WHERE id = ? AND deleted_at IS NULL",
                                     [.uuid(id)]) { row in
                SnippetUsage(lastUsedAt: row.isNull(0) ? nil : row.date(0), useCount: row.int(1))
            }
            guard let usage else { throw StoreError.notFound(id: id) }
            return usage
        }
    }

    /// Most recently used first.
    func recentlyUsed(limit: Int) throws -> [Snippet] {
        try read { db in
            try load(db, where: "deleted_at IS NULL AND last_used_at IS NOT NULL", order: "last_used_at DESC, id",
                     limit: limit).map(\.snippet)
        }
    }

    // MARK: History and tags

    /// Saved snapshots of a snippet (also of one in the trash), newest first.
    func revisions(of id: UUID) throws -> [SnippetRevision] {
        try read { db in
            try db.rows("""
            SELECT revision, recorded_at, snapshot FROM snippet_revisions WHERE snippet_id = ? ORDER BY revision DESC
            """, [.uuid(id)]) { row in
                do {
                    let snippet = try JSONDecoder().decode(Snippet.self, from: row.data(2))
                    return SnippetRevision(revision: row.int(0), recordedAt: row.date(1), snippet: snippet)
                } catch let error as KeyloomError {
                    throw error
                } catch {
                    throw StoreError.corruptRecord(column: "snapshot")
                }
            }
        }
    }

    /// Tags of live snippets with their counts, by tag.
    func tags() throws -> [TagSummary] {
        try read { db in
            try db.rows("""
            SELECT t.tag, count(*) FROM snippet_tags t JOIN snippets s ON s.id = t.snippet_id
            WHERE s.deleted_at IS NULL GROUP BY t.tag ORDER BY t.tag
            """) { TagSummary(tag: $0.string(0), count: $0.int(1)) }
        }
    }

    // MARK: Private

    private struct Loaded {
        let snippet: Snippet
        let deletedAt: Date?
    }

    private func connection() throws -> SQLiteConnection {
        guard let database else { throw StoreError.closed }
        return database
    }

    private func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T { try body(try connection()) }

    private func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let db = try connection()
        return try db.transaction { try body(db) }
    }

    private static func iconValues(_ icon: SnippetIcon) -> [SQLValue] {
        switch icon {
        case .emoji(let value): [.text("emoji"), .text(value)]
        case .symbol(let value): [.text("symbol"), .text(value)]
        }
    }

    private static func validate(_ snippet: Snippet) throws {
        func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isBlank(snippet.name) { throw KeyloomError.invalidSnippet(field: "name", reason: "must not be blank") }
        if let keyword = snippet.keyword, isBlank(keyword) {
            throw KeyloomError.invalidSnippet(field: "keyword", reason: "must not be blank")
        }
        if snippet.revision < 1 { throw KeyloomError.invalidSnippet(field: "revision", reason: "must be at least 1") }
        if snippet.tags.contains(where: isBlank) { throw KeyloomError.invalidSnippet(field: "tags", reason: "must not be blank") }
        if Set(snippet.tags).count != snippet.tags.count {
            throw KeyloomError.invalidSnippet(field: "tags", reason: "must not repeat")
        }
        try snippet.template.validate()
    }

    private func requireLive(_ db: SQLiteConnection, _ id: UUID) throws {
        guard try db.first("SELECT 1 FROM snippets WHERE id = ? AND deleted_at IS NULL", [.uuid(id)], map: { $0.int(0) }) != nil else {
            throw StoreError.notFound(id: id)
        }
    }

    /// Rows plus their tags (one query for all tags). Filters bind as parameters; only fixed SQL fragments
    /// are ever interpolated.
    private func load(_ db: SQLiteConnection, where condition: String, _ parameters: [SQLValue] = [],
                      order: String = SnippetStore.defaultOrder, limit: Int? = nil) throws -> [Loaded] {
        let tail = " WHERE \(condition) ORDER BY \(order)" + (limit == nil ? "" : " LIMIT ?")
        let bound = parameters + (limit.map { [SQLValue.int(Int64($0))] } ?? [])
        var tagsByID: [String: [String]] = [:]
        _ = try db.rows("SELECT snippet_id, tag FROM snippet_tags WHERE snippet_id IN (SELECT id FROM snippets\(tail)) ORDER BY snippet_id, position",
                    bound) { row in
            tagsByID[row.string(0), default: []].append(row.string(1))
        }
        return try db.rows("SELECT \(Self.columns) FROM snippets\(tail)", bound) { row in
            guard let id = UUID(uuidString: row.string(0)) else { throw StoreError.corruptRecord(column: "id") }
            let icon: SnippetIcon = row.string(2) == "emoji" ? .emoji(row.string(3)) : .symbol(row.string(3))
            let snippet = Snippet(id: id, name: row.string(1), icon: icon, keyword: row.isNull(4) ? nil : row.string(4),
                                  enabled: row.int(5) == 1, tags: tagsByID[row.string(0)] ?? [], pinned: row.int(6) == 1,
                                  revision: row.int(7), template: try Document.decode(from: row.data(8)),
                                  createdAt: row.date(9), updatedAt: row.date(10),
                                  lastUsedAt: row.isNull(11) ? nil : row.date(11))
            return Loaded(snippet: snippet, deletedAt: row.isNull(12) ? nil : row.date(12))
        }
    }

    private func replaceTags(_ db: SQLiteConnection, of snippet: Snippet) throws {
        try db.run("DELETE FROM snippet_tags WHERE snippet_id = ?", [.uuid(snippet.id)])
        for (position, tag) in snippet.tags.enumerated() {
            try db.run("INSERT INTO snippet_tags (snippet_id, tag, position) VALUES (?, ?, ?)",
                       [.uuid(snippet.id), .text(tag), .int(Int64(position))])
        }
    }

    /// Appends the snapshot for the snippet's current revision and prunes the oldest beyond the cap.
    private func recordRevision(_ db: SQLiteConnection, _ snippet: Snippet) throws {
        try db.run("INSERT INTO snippet_revisions (snippet_id, revision, recorded_at, snapshot) VALUES (?, ?, ?, ?)",
                   [.uuid(snippet.id), .int(Int64(snippet.revision)), .date(now()), .blob(try JSONEncoder().encode(snippet))])
        try db.run("DELETE FROM snippet_revisions WHERE snippet_id = ? AND revision <= ?",
                   [.uuid(snippet.id), .int(Int64(snippet.revision - Self.maxRevisionsPerSnippet))])
    }

    private func reloadAndRecord(_ db: SQLiteConnection, _ id: UUID) throws -> Snippet {
        guard let snippet = try load(db, where: "id = ?", [.uuid(id)]).first?.snippet else { throw StoreError.notFound(id: id) }
        try recordRevision(db, snippet)
        return snippet
    }

    /// The partial unique index is the authority on keyword uniqueness. When it rejects a write this
    /// names the snippet that owns the keyword, so the caller gets a typed error and no text.
    private func mappingKeywordConflict(_ db: SQLiteConnection, id: UUID, keyword: String?, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch StoreError.sqlite(let code, _) where code == Self.uniqueConstraint {
            guard let keyword, let ownerText = try db.first("""
            SELECT id FROM snippets WHERE keyword = ? AND enabled = 1 AND deleted_at IS NULL AND id != ?
            """, [.text(keyword), .uuid(id)], map: { $0.string(0) }), let owner = UUID(uuidString: ownerText) else {
                throw StoreError.sqlite(code: code, context: "step")
            }
            throw StoreError.keywordConflict(existingID: owner)
        }
    }

    // MARK: Opening

    private static func openDatabase(at url: URL, migrations: [Migration]) throws -> SQLiteConnection {
        // Create the file owner-only before SQLite does, so there is no window with default permissions.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let db = try SQLiteConnection(path: url.path)
        guard try db.first("PRAGMA journal_mode = WAL", map: { $0.string(0) }) == "wal" else {
            throw StoreError.sqlite(code: SQLITE_ERROR, context: "journal_mode")
        }
        let current = try db.userVersion
        for migration in migrations where migration.version > current {
            try db.transaction {
                try migration.apply(db)
                try db.setUserVersion(migration.version)
            }
        }
        return db
    }
}
