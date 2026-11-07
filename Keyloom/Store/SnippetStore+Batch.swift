import Foundation

struct BatchImportResult: Sendable, Equatable {
    /// As stored, in input order: ids, enabled flags and keywords may differ from what was passed in.
    let stored: [Snippet]
    let disabledForKeywordConflict: [UUID]
}

struct RestoreResult: Sendable, Equatable {
    /// Added, or taken back from the trash.
    let created: [UUID]
    let updated: [UUID]
    /// Live snippets that were not in the target; they are in the trash, so the restore itself is recoverable.
    let deleted: [UUID]
    let disabledForKeywordConflict: [UUID]
}

/// Multi-snippet writes, each one transaction: all of it commits (rows, tags, history and the sync outbox
/// together) or none of it does. Inputs are validated before the first write.
extension SnippetStore {
    /// Imports `snippets` as given (ids, revisions and dates kept; usage starts empty). Authoritative against
    /// the database at commit time, whatever a preview saw earlier:
    /// - an id that already exists, live or in the trash, is replaced by a fresh one, so nothing is overwritten;
    /// - an enabled snippet whose keyword an enabled live snippet already owns, or an earlier entry of this
    ///   batch, is stored disabled (its keyword kept).
    func importBatch(_ snippets: [Snippet]) throws -> BatchImportResult {
        let prepared = try snippets.map(Self.prepared)
        return try write { db in
            var stored: [Snippet] = []
            var disabled: [UUID] = []
            for var snippet in prepared {
                while try rowExists(db, snippet.id) { snippet = snippet.reidentified(makeID()) }
                if try disableIfKeywordTaken(db, &snippet) { disabled.append(snippet.id) }
                try insertRow(db, snippet)
                stored.append(snippet)
            }
            return BatchImportResult(stored: stored, disabledForKeywordConflict: disabled)
        }
    }

    /// Makes the live library equal `target` (a snapshot's snippets): changed snippets are rewritten, missing
    /// ones come back (also from the trash), live snippets absent from `target` go to the trash. Revisions move
    /// forward and every change is journaled, so sync sees the restore as ordinary edits. Unchanged snippets
    /// write nothing; usage is device-local and untouched. A keyword that two enabled snippets of `target` both
    /// claim goes to the first, the rest are disabled.
    func restoreLibrary(to target: [Snippet]) throws -> RestoreResult {
        let prepared = try target.map(Self.prepared)
        var seen = Set<UUID>()
        for snippet in prepared where !seen.insert(snippet.id).inserted { throw StoreError.alreadyExists(id: snippet.id) }

        return try write { db in
            let live = Dictionary(uniqueKeysWithValues: try contents().snippets.map { ($0.id, $0) })
            var revisions: [UUID: Int] = [:]
            _ = try db.rows("SELECT id, revision FROM snippets") { row in
                if let id = UUID(uuidString: row.string(0)) { revisions[id] = row.int(1) }
            }

            var deleted: [UUID] = []
            for id in live.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !seen.contains(id) {
                let revision = (revisions[id] ?? 0) + 1
                let moment = SQLValue.date(now())
                try db.run("UPDATE snippets SET deleted_at = ?, updated_at = ?, revision = ? WHERE id = ?",
                           [moment, moment, .int(Int64(revision)), .uuid(id)])
                try journal(db, id: id, operation: .delete, revision: revision)
                deleted.append(id)
            }

            let changed = prepared.filter { snippet in
                guard let current = live[snippet.id] else { return true }
                return !current.hasSameContent(as: snippet)
            }
            // Free every keyword that is about to be rewritten first, so two snippets can swap keywords.
            for snippet in changed where revisions[snippet.id] != nil {
                try db.run("UPDATE snippets SET keyword = NULL WHERE id = ?", [.uuid(snippet.id)])
            }

            var created: [UUID] = []
            var updated: [UUID] = []
            var disabled: [UUID] = []
            for var snippet in changed {
                if try disableIfKeywordTaken(db, &snippet) { disabled.append(snippet.id) }
                if let previous = revisions[snippet.id] {
                    snippet.revision = previous + 1
                    snippet.updatedAt = now()
                    try db.run("""
                    UPDATE snippets SET name = ?, icon_kind = ?, icon_value = ?, keyword = ?, enabled = ?, pinned = ?,
                                        revision = ?, template = ?, created_at = ?, updated_at = ?, deleted_at = NULL
                    WHERE id = ?
                    """, [.text(snippet.name)] + Self.iconValues(snippet.icon) + [
                        .text(orNull: snippet.keyword), .bool(snippet.enabled), .bool(snippet.pinned),
                        .int(Int64(snippet.revision)), .blob(try snippet.template.encoded()), .date(snippet.createdAt),
                        .date(snippet.updatedAt), .uuid(snippet.id),
                    ])
                    try replaceTags(db, of: snippet)
                    try recordRevision(db, snippet)
                    try journal(db, id: snippet.id, operation: .upsert, revision: snippet.revision)
                    if live[snippet.id] == nil { created.append(snippet.id) } else { updated.append(snippet.id) }
                } else {
                    try insertRow(db, snippet)
                    created.append(snippet.id)
                }
            }
            return RestoreResult(created: created, updated: updated, deleted: deleted, disabledForKeywordConflict: disabled)
        }
    }

    // MARK: Private

    /// Validated, with the keyword in canonical form and usage cleared, like `create`.
    private static func prepared(_ snippet: Snippet) throws -> Snippet {
        try validate(snippet)
        var result = snippet
        result.keyword = canonical(result.keyword)
        result.lastUsedAt = nil
        return result
    }

    private func rowExists(_ db: SQLiteConnection, _ id: UUID) throws -> Bool {
        try db.first("SELECT 1 FROM snippets WHERE id = ?", [.uuid(id)], map: { $0.int(0) }) != nil
    }

    /// Disables `snippet` when it is enabled and an enabled live snippet already holds its keyword. Reads the
    /// table, so earlier writes of the same transaction count. True when it changed the snippet.
    private func disableIfKeywordTaken(_ db: SQLiteConnection, _ snippet: inout Snippet) throws -> Bool {
        guard snippet.enabled, let keyword = snippet.keyword else { return false }
        let taken = try db.first("""
        SELECT 1 FROM snippets WHERE keyword = ? AND enabled = 1 AND deleted_at IS NULL AND id != ?
        """, [.text(keyword), .uuid(snippet.id)], map: { $0.int(0) }) != nil
        if taken { snippet.enabled = false }
        return taken
    }

    private func insertRow(_ db: SQLiteConnection, _ snippet: Snippet) throws {
        try db.run("""
        INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, pinned, revision, template,
                              created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [.uuid(snippet.id), .text(snippet.name)] + Self.iconValues(snippet.icon) + [
            .text(orNull: snippet.keyword), .bool(snippet.enabled), .bool(snippet.pinned), .int(Int64(snippet.revision)),
            .blob(try snippet.template.encoded()), .date(snippet.createdAt), .date(snippet.updatedAt),
        ])
        try replaceTags(db, of: snippet)
        try recordRevision(db, snippet)
        try journal(db, id: snippet.id, operation: .upsert, revision: snippet.revision)
    }
}

private extension Snippet {
    func reidentified(_ newID: UUID) -> Snippet {
        Snippet(id: newID, name: name, icon: icon, keyword: keyword, enabled: enabled, tags: tags, pinned: pinned,
                revision: 1, template: template, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// The user-visible content: not identity, revision, dates or usage.
    func hasSameContent(as other: Snippet) -> Bool {
        name == other.name && icon == other.icon && keyword == other.keyword && enabled == other.enabled
            && tags == other.tags && pinned == other.pinned && template == other.template
    }
}
