import Foundation

/// The app-facing snippet API for the input host, the library UI and import/sync. One actor owns the
/// `SnippetStore` and keeps everything derived from it consistent: after every committed mutation it reloads
/// the library, rebuilds the keyword index and the search index, swaps the index into `KeywordIndexStore`, and
/// only then returns and publishes the change. The reload happens on this actor, never on a keyboard callback.
/// `recordUsage` is the exception: usage never affects the indexes, so it patches the snapshot in place.
///
/// - Reads (`allSnippets`, `snippet(id:)`, `search`, `tags`, diagnostics) come from the in-memory snapshot, so
///   they reflect every mutation that has returned.
/// - The input host owns `keywordMatcher`. The matcher reads `KeywordIndexStore` directly, never this actor,
///   so typing is never blocked on database work. It is `nonisolated` and safe to call from any thread.
/// - Concurrent mutations are serialized by the store; each reload is ticketed, and a reload that finishes
///   after a newer one is dropped, so the swapped state is never older than a committed write.
/// - Updates are last-writer-wins, as in `SnippetStore`. `rename` and `setPinned` change one field of the
///   stored snippet, so they do not overwrite other fields a concurrent `update` saved before them.
/// - Typed text, clipboard values and arguments pass through `expansion` and `preview` only: they are never
///   stored, logged or put into a `LibraryChange` or an error.
/// - `changes` is single-consumer: iterate it from one task. It finishes when `close()` is called.
actor SnippetLibrary {
    /// Nonisolated so the keyboard side can feed it directly.
    nonisolated let keywordMatcher: KeywordMatcher
    nonisolated let changes: AsyncStream<LibraryChange>

    let store: SnippetStore
    private let keywordIndexStore = KeywordIndexStore()
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID
    let changeContinuation: AsyncStream<LibraryChange>.Continuation
    private var snapshot: [Snippet] = []
    private var unreadable: [UnreadableRecord] = []
    private var searchIndex = SearchIndex(snippets: [])
    private var issuedTicket = 0
    private var appliedTicket = 0
    /// Full reloads performed (open, committed content mutations, sync). Diagnostics and tests: usage never adds one.
    private(set) var reloadCount = 0

    /// Opens (creating, migrating and backing up as needed) the library at `url` and loads it. Opening
    /// blocks on file I/O: do it off the keyboard callback.
    init(url: URL, backupDirectory: URL, syncAccount: String = "local",
         now: @escaping @Sendable () -> Date = { Date() }, makeID: @escaping @Sendable () -> UUID = { UUID() }) async throws {
        store = try SnippetStore(url: url, backupDirectory: backupDirectory, syncAccount: syncAccount, now: now, makeID: makeID)
        self.now = now
        self.makeID = makeID
        keywordMatcher = KeywordMatcher(store: keywordIndexStore)
        (changes, changeContinuation) = AsyncStream.makeStream(of: LibraryChange.self)
        try await reload()
    }

    /// Builds the library on a store that already exists, so the library and `SyncController` share one
    /// connection and one journal account: edits made here land in the outbox under the account sync is running
    /// for. Hand `syncStore` to the controller and `reloadAfterSync` as its `onLibraryChanged`.
    init(store: SnippetStore) async throws {
        self.store = store
        now = store.now
        makeID = store.makeID
        keywordMatcher = KeywordMatcher(store: keywordIndexStore)
        (changes, changeContinuation) = AsyncStream.makeStream(of: LibraryChange.self)
        try await reload()
    }

    /// The store behind this library, for `SyncController`. Do not open a second store on the same file.
    nonisolated var syncStore: SnippetStore { store }

    /// For `SyncController`'s `onLibraryChanged`: sync changed the stored library, so rebuild the snapshot and
    /// indexes and tell observers. A failed reload leaves the previous snapshot; the next change retries.
    func reloadAfterSync() async {
        guard (try? await reload()) != nil else { return }
        changeContinuation.yield(.remoteChangesApplied)
    }

    /// Closes the database and finishes `changes`. Later mutations throw `StoreError.closed`.
    func close() async {
        await store.close()
        changeContinuation.finish()
    }

    // MARK: Reads

    /// Pinned first, then by name.
    func allSnippets() -> [Snippet] { snapshot }

    func snippet(id: UUID) -> Snippet? { snapshot.first { $0.id == id } }

    /// Tags of live snippets with counts, by tag.
    func tags() -> [TagSummary] {
        Dictionary(grouping: snapshot.flatMap(\.tags), by: { $0 })
            .map { TagSummary(tag: $0.key, count: $0.value.count) }
            .sorted { $0.tag < $1.tag }
    }

    /// Rows the library could not read (for example written by a newer Keyloom). They are left out of everything
    /// above, so the rest of the library works; delete one with `delete(id:)` when its `rowID` is a snippet ID.
    func unreadableRecords() -> [UnreadableRecord] { unreadable }

    func deletedSnippets() async throws -> [DeletedSnippet] { try await store.deletedSnippets() }

    /// `tags` and a `.tag` filter combine with AND. An empty result says why: `.emptyLibrary` only when the
    /// library has no snippets, else `.noMatches`.
    func search(query: String, tags: Set<String> = [], filter: LibraryFilter = .all) -> SearchOutcome {
        var wanted = tags
        if case .tag(let tag) = filter { wanted.insert(tag) }
        let outcome = searchIndex.search(query: query, tags: wanted)
        guard case .results(let hits) = outcome else { return outcome }
        var kept = hits
        switch filter {
        case .all, .tag: break
        case .pinned: kept = hits.filter(\.snippet.pinned)
        case .recentlyUsed:
            kept = hits.enumerated().filter { $0.element.snippet.lastUsedAt != nil }
                .sorted { ($0.element.snippet.lastUsedAt!, $1.offset) > ($1.element.snippet.lastUsedAt!, $0.offset) }
                .map(\.element)
        }
        return kept.isEmpty ? .noMatches : .results(kept)
    }

    // MARK: Mutations

    /// A new snippet with a generated ID, for the editor's "New snippet".
    func create(name: String, icon: SnippetIcon, keyword: String?, enabled: Bool = true, tags: [String] = [],
                template: Document) async throws -> Snippet {
        try await create(Snippet(id: makeID(), name: name, icon: icon, keyword: keyword, enabled: enabled, tags: tags,
                                 template: template, createdAt: now()))
    }

    /// Stores `snippet` as given (so an import keeps its ID and revision). Throws `StoreError.keywordConflict`
    /// when another enabled snippet owns the keyword.
    func create(_ snippet: Snippet) async throws -> Snippet {
        try await commit({ .created($0.id) }) { try await $0.create(snippet) }
    }

    func update(_ snippet: Snippet) async throws -> Snippet {
        try await commit({ .updated($0.id) }) { try await $0.update(snippet) }
    }

    /// Changes only the name; the UUID is kept. A blank name throws `KeyloomError.invalidSnippet`.
    func rename(id: UUID, to name: String) async throws -> Snippet {
        try await commit({ .updated($0.id) }) { store in
            guard var current = try await store.snippet(id: id) else { throw StoreError.notFound(id: id) }
            try current.rename(to: name, at: self.now())
            return try await store.update(current)
        }
    }

    /// A copy with a new ID. A copy of a keyworded snippet starts disabled (see `SnippetStore.duplicate`).
    func duplicate(id: UUID) async throws -> Snippet {
        try await commit({ .created($0.id) }) { try await $0.duplicate(id: id) }
    }

    func setPinned(_ pinned: Bool, id: UUID) async throws -> Snippet {
        try await commit({ .updated($0.id) }) { try await $0.setPinned(pinned, id: id) }
    }

    func delete(id: UUID) async throws {
        try await commit({ _ in .deleted(id) }) { try await $0.delete(id: id) }
    }

    /// Immediate undo of `delete`. Throws `StoreError.keywordConflict` if another enabled snippet took the
    /// keyword meanwhile; the snippet stays in the trash.
    func undoDelete(id: UUID) async throws -> Snippet {
        try await commit({ .restored($0.id) }) { try await $0.restore(id: id) }
    }

    /// Restore from the trash. Never fails on a keyword conflict: the snippet comes back disabled instead.
    func restore(id: UUID) async throws -> Snippet {
        try await commit({ .restored($0.id) }) { try await $0.restore(id: id, disablingOnKeywordConflict: true) }
    }

    /// Records that the snippet was expanded or inserted (device-local, no revision bump). Only the ID is kept.
    /// Usage changes only recency, so the snapshot and search index are patched in place: no reload, and the
    /// keyword index (which never reads usage) is left alone.
    func recordUsage(id: UUID) async throws {
        let usedAt = try await store.recordUsage(id: id)
        if let index = snapshot.firstIndex(where: { $0.id == id }) { snapshot[index].lastUsedAt = usedAt }
        searchIndex.setLastUsedAt(usedAt, for: id)
        changeContinuation.yield(.usageRecorded(id))
    }

    // MARK: Keyword diagnostics

    /// Library-wide findings over the stored snippets.
    func keywordDiagnostics() -> KeywordDiagnostics {
        Self.diagnostics(for: snapshot, focus: nil)
    }

    /// Findings that involve `draft` (the editor's unsaved state), judged as if it were saved in place of the
    /// stored snippet with the same ID.
    func keywordDiagnostics(for draft: Snippet) -> KeywordDiagnostics {
        Self.diagnostics(for: snapshot.filter { $0.id != draft.id } + [draft], focus: draft.id)
    }

    // MARK: Expansion

    /// For a match the input host just got from `keywordMatcher`. Throws `StoreError.notFound` when the snippet
    /// was deleted after the match. When `needsArguments`, prompt, then call again with the answers.
    /// Recording usage is left to the host, once the text is actually inserted.
    func expansion(for match: KeywordMatch, arguments: [String: String] = [:],
                   environment: RenderEnvironment) throws -> ExpansionOutcome {
        guard let snippet = snippet(id: match.snippetID) else { throw StoreError.notFound(id: match.snippetID) }
        return try Self.expand(snippet.template, arguments: arguments, environment: environment)
    }

    /// "Try expansion" for an unsaved template. Pure: touches no stored state.
    nonisolated func preview(for template: Document, arguments: [String: String] = [:],
                             environment: RenderEnvironment) throws -> ExpansionOutcome {
        try Self.expand(template, arguments: arguments, environment: environment)
    }

    // MARK: Private

    private static func expand(_ template: Document, arguments: [String: String],
                               environment: RenderEnvironment) throws -> ExpansionOutcome {
        let missing = TemplateRenderer.requiredArguments(in: template, provided: arguments)
        if !missing.isEmpty { return .needsArguments(missing) }
        return .rendered(try TemplateRenderer(environment: environment).render(template, arguments: arguments))
    }

    private static func diagnostics(for snippets: [Snippet], focus: UUID?) -> KeywordDiagnostics {
        let analysis = KeywordConflicts.analyze(snippets)
        let oversize = ActiveKeyword.from(snippets)
            .filter { $0.keyword.unicodeScalars.count > KeywordIndex.maxKeywordScalars }.map(\.snippetID)
        guard let focus else {
            return KeywordDiagnostics(conflicts: analysis.conflicts, overlaps: analysis.overlaps, oversizeKeywordSnippetIDs: oversize)
        }
        return KeywordDiagnostics(
            conflicts: analysis.conflicts.filter { $0.snippetIDs.contains(focus) },
            overlaps: analysis.overlaps.filter { $0.shorterSnippetIDs.contains(focus) || $0.longerSnippetIDs.contains(focus) },
            oversizeKeywordSnippetIDs: oversize.filter { $0 == focus })
    }

    /// Runs one store write, brings the derived state up to date, then publishes. A failed write changes
    /// and publishes nothing.
    private func commit<T>(_ change: (T) -> LibraryChange, _ write: (SnippetStore) async throws -> T) async throws -> T {
        let result = try await write(store)
        try await reload()
        changeContinuation.yield(change(result))
        return result
    }

    func reload() async throws {
        reloadCount += 1
        issuedTicket += 1
        let ticket = issuedTicket
        let contents = try await store.contents()
        let snippets = contents.snippets
        // A newer reload already applied a state read after this write committed.
        guard ticket > appliedTicket else { return }
        appliedTicket = ticket
        snapshot = snippets
        unreadable = contents.unreadable
        searchIndex = SearchIndex(snippets: snippets)
        keywordIndexStore.replace(KeywordIndex(snippets: snippets))
    }
}
