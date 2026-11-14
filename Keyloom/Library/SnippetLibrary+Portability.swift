import Foundation

struct ImportOutcome: Equatable, Sendable {
    /// As stored, in file order.
    let imported: [Snippet]
    /// Imported but left disabled because another enabled snippet owns the keyword.
    let disabledForKeywordConflict: [UUID]
}

struct RestoreOutcome: Equatable, Sendable {
    let created: [UUID]
    let updated: [UUID]
    let deleted: [UUID]
    let disabledForKeywordConflict: [UUID]
}

/// Import, export, snapshots and restore on the app-facing library. Every write is one store transaction
/// followed by the same derived-state refresh and change publication as the other mutations; a failure
/// changes and publishes nothing. Imported and restored text never reaches a log, a change or an error.
extension SnippetLibrary {
    // MARK: Export

    func exportNative() throws -> Data {
        try NativeFormat.export(allSnippets(), exportedAt: now())
    }

    func exportRaycast() throws -> RaycastFormat.Export {
        try RaycastFormat.export(allSnippets())
    }

    // MARK: Import

    /// Reads an import file against the current library. Pure: nothing is written. Throws `PortabilityError`
    /// for a file that cannot be imported at all.
    func previewImport(_ data: Data) throws -> ImportPreview {
        try ImportPlanner.preview(data, existing: allSnippets(), now: now(), makeID: makeID)
    }

    /// Commits the selected importable items (all of them when `selecting` is nil) in one transaction, after
    /// saving a pre-import snapshot of the current library. If the snapshot cannot be written, nothing is
    /// imported. Nothing selected writes nothing, not even a snapshot.
    func commitImport(_ preview: ImportPreview, selecting: Set<Int>? = nil, snapshots: SnapshotManager) async throws -> ImportOutcome {
        let chosen = preview.selected(selecting)
        guard !chosen.isEmpty else { return ImportOutcome(imported: [], disabledForKeywordConflict: []) }
        _ = try await snapshots.takeSafeguard(.preImport, snippets: allSnippets())
        let result = try await store.importBatch(chosen.map(\.snippet))
        try await reload()
        for snippet in result.stored { broadcaster.yield(.created(snippet.id)) }
        // The preview already disabled what it saw clashing; the store disables what clashed since. `stored` keeps input order.
        let disabled = zip(chosen, result.stored).filter { $0.conflictsWith != nil || result.disabledForKeywordConflict.contains($1.id) }.map(\.1.id)
        return ImportOutcome(imported: result.stored, disabledForKeywordConflict: disabled)
    }

    // MARK: Snapshots and restore

    /// The daily snapshot of the current library, or nil when there is nothing new to keep (see `SnapshotManager`).
    func takeDailySnapshot(using snapshots: SnapshotManager) async throws -> SnapshotInfo? {
        try await snapshots.takeDailyIfChanged(allSnippets())
    }

    /// Validates `snapshot` first (a bad file throws a `SnapshotError` and nothing else happens), saves a
    /// pre-restore snapshot of the current library, then makes the library equal the snapshot in one
    /// transaction that also queues every change for sync.
    func restore(from snapshot: SnapshotInfo, using snapshots: SnapshotManager) async throws -> RestoreOutcome {
        let contents = try await snapshots.load(snapshot)
        _ = try await snapshots.takeSafeguard(.preRestore, snippets: allSnippets())
        let result = try await store.restoreLibrary(to: contents.snippets)
        try await reload()
        for id in result.created { broadcaster.yield(.created(id)) }
        for id in result.updated { broadcaster.yield(.updated(id)) }
        for id in result.deleted { broadcaster.yield(.deleted(id)) }
        return RestoreOutcome(created: result.created, updated: result.updated, deleted: result.deleted,
                              disabledForKeywordConflict: result.disabledForKeywordConflict)
    }

    /// The sync intents queued so far for the current account, oldest first.
    func pendingSyncChanges(limit: Int = 1_000) async throws -> [OutboxEntry] {
        try await store.pending(limit: limit)
    }
}
