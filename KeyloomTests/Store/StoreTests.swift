import XCTest
@testable import Keyloom

final class StoreTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    // MARK: Schema, stable IDs, reopen

    func testCreateThenReadByStableID() async throws {
        let store = try openStore(at: try databaseURL())
        let input = makeSnippet(tags: ["work", "mail"])
        let created = try await store.create(input)
        XCTAssertEqual(created, input)
        let fetched = try await store.snippet(id: input.id)
        XCTAssertEqual(fetched, input)
        let missing = try await store.snippet(id: UUID())
        XCTAssertNil(missing)
    }

    func testReopenedFileDatabaseKeepsSchemaVersionWalAndRowsByID() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let input = makeSnippet(tags: ["b", "a"], text: "Grüße 👩‍👩‍👧")
        _ = try await store.create(input)
        await store.close()

        let reopened = try openStore(at: url)
        let fetched = try await reopened.snippet(id: input.id)
        XCTAssertEqual(fetched, input)
        XCTAssertEqual(fetched?.tags, ["b", "a"], "tag order survives")

        let raw = try RawDatabase(url, readOnly: true)
        XCTAssertEqual(try raw.userVersion, Migrations.all.count)
        XCTAssertEqual(try raw.text("PRAGMA journal_mode"), "wal")
    }

    func testDatabaseFileIsOwnerOnly() async throws {
        let url = try databaseURL()
        _ = try openStore(at: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRenameKeepsUUIDAndStoreOwnsRevision() async throws {
        let store = try openStore(at: try databaseURL())
        let created = try await store.create(makeSnippet(name: "Old"))
        clock.advance(by: 60)
        var edited = created
        try edited.rename(to: "New", at: clock.now)
        edited.revision = 999 // a caller-supplied revision is not trusted
        let updated = try await store.update(edited)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.name, "New")
        XCTAssertEqual(updated.revision, created.revision + 1)
        XCTAssertEqual(updated.createdAt, created.createdAt)
        XCTAssertEqual(updated.updatedAt, clock.now)
        let fetched = try await store.snippet(id: created.id)
        XCTAssertEqual(fetched, updated)
    }

    func testRejectsInvalidSnippetsAndDuplicateIDs() async throws {
        let store = try openStore(at: try databaseURL())
        let invalid: [(Snippet, String)] = [
            (makeSnippet(name: "  "), "name"),
            (makeSnippet(keyword: ""), "keyword"),
            (makeSnippet(tags: ["a", "a"]), "tags"),
            (makeSnippet(tags: [" "]), "tags"),
            ({ var s = makeSnippet(); s.revision = 0; return s }(), "revision"),
        ]
        for (snippet, field) in invalid {
            do {
                _ = try await store.create(snippet)
                XCTFail("expected invalidSnippet(\(field))")
            } catch let error as KeyloomError {
                guard case .invalidSnippet(let failed, _) = error else { return XCTFail("wrong error \(error)") }
                XCTAssertEqual(failed, field)
            }
        }
        let first = makeSnippet(keyword: nil)
        _ = try await store.create(first)
        await assertThrows(StoreError.alreadyExists(id: first.id)) { _ = try await store.create(first) }
        let all = try await store.allSnippets()
        XCTAssertEqual(all.count, 1)
    }

    func testUpdateOfUnknownSnippetFails() async throws {
        let store = try openStore(at: try databaseURL())
        let ghost = makeSnippet()
        await assertThrows(StoreError.notFound(id: ghost.id)) { _ = try await store.update(ghost) }
    }

    // MARK: Duplicate

    func testDuplicateGetsNewIDSuffixDisabledKeywordAndTags() async throws {
        let store = try openStore(at: try databaseURL())
        var original = try await store.create(makeSnippet(name: "Sig", tags: ["mail"]))
        original = try await store.setPinned(true, id: original.id)
        let copy = try await store.duplicate(id: original.id)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Sig copy")
        XCTAssertEqual(copy.keyword, original.keyword, "keyword text kept so the user can edit it")
        XCTAssertFalse(copy.enabled, "an enabled keyword would collide with the original")
        XCTAssertEqual(copy.tags, ["mail"])
        XCTAssertEqual(copy.template, original.template)
        XCTAssertFalse(copy.pinned)
        XCTAssertEqual(copy.revision, 1)
        let stored = try await store.snippet(id: copy.id)
        XCTAssertEqual(stored, copy)
    }

    func testDuplicateWithoutKeywordStaysEnabled() async throws {
        let store = try openStore(at: try databaseURL())
        let original = try await store.create(makeSnippet(keyword: nil))
        let copy = try await store.duplicate(id: original.id)
        XCTAssertTrue(copy.enabled)
        XCTAssertNil(copy.keyword)
    }

    func testDuplicateOfUnknownOrDeletedSnippetFails() async throws {
        let store = try openStore(at: try databaseURL())
        let unknown = UUID()
        await assertThrows(StoreError.notFound(id: unknown)) { _ = try await store.duplicate(id: unknown) }
        let snippet = try await store.create(makeSnippet())
        try await store.delete(id: snippet.id)
        await assertThrows(StoreError.notFound(id: snippet.id)) { _ = try await store.duplicate(id: snippet.id) }
    }

    // MARK: Keyword uniqueness

    func testSecondEnabledSnippetWithSameKeywordIsTypedConflict() async throws {
        let store = try openStore(at: try databaseURL())
        let first = try await store.create(makeSnippet())
        let second = makeSnippet(name: "Other")
        await assertThrows(StoreError.keywordConflict(existingID: first.id)) { _ = try await store.create(second) }
        let stored = try await store.snippet(id: second.id)
        XCTAssertNil(stored, "the failed create left no row")
    }

    func testConflictErrorCarriesNoKeywordText() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(keyword: ";secret-keyword"))
        do {
            _ = try await store.create(makeSnippet(keyword: ";secret-keyword"))
            XCTFail("expected conflict")
        } catch {
            XCTAssertFalse(String(describing: error).contains("secret-keyword"))
            XCTAssertFalse(error.localizedDescription.contains("secret-keyword"))
        }
    }

    func testDisabledNilAndDifferentCaseKeywordsDoNotConflict() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(keyword: ";hi"))
        _ = try await store.create(makeSnippet(keyword: ";hi", enabled: false))
        _ = try await store.create(makeSnippet(keyword: ";Hi"))
        _ = try await store.create(makeSnippet(keyword: nil))
        _ = try await store.create(makeSnippet(keyword: nil))
        let all = try await store.allSnippets()
        XCTAssertEqual(all.count, 5)
    }

    func testEnablingOrRenamingKeywordIntoConflictFailsAndLeavesRowUnchanged() async throws {
        let store = try openStore(at: try databaseURL())
        let first = try await store.create(makeSnippet(keyword: ";a"))
        let second = try await store.create(makeSnippet(keyword: ";b", enabled: false))

        var enabling = second
        enabling.keyword = ";a"
        enabling.enabled = true
        await assertThrows(StoreError.keywordConflict(existingID: first.id)) { _ = try await store.update(enabling) }

        let unchanged = try await store.snippet(id: second.id)
        XCTAssertEqual(unchanged, second)
        let revisions = try await store.revisions(of: second.id)
        XCTAssertEqual(revisions.map(\.revision), [1])
    }

    func testUniquenessIsEnforcedByTheDatabaseItself() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        _ = try await store.create(makeSnippet(keyword: ";a"))
        let raw = try RawDatabase(url)
        let insert = """
        INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, revision, template, created_at, updated_at)
        VALUES ('\(UUID().uuidString)', 'x', 'emoji', 'x', ';a', 1, 1, x'7B7D', 0, 0)
        """
        XCTAssertThrowsError(try raw.execute(insert)) { error in
            XCTAssertTrue("\(error)".contains("UNIQUE constraint failed: snippets.keyword"), "rejected by the partial unique index: \(error)")
        }
    }

    func testConcurrentWritersFromTwoConnectionsYieldExactlyOneWinner() async throws {
        let url = try databaseURL()
        let stores = [try openStore(at: url), try openStore(at: url)]
        let candidates = (0..<16).map { _ in makeSnippet(keyword: ";race") }
        let outcomes = await withTaskGroup(of: Result<Void, StoreError>.self) { group in
            for (index, candidate) in candidates.enumerated() {
                let store = stores[index % 2]
                group.addTask {
                    do { _ = try await store.create(candidate); return .success(()) } catch let error as StoreError { return .failure(error) } catch { return .failure(.sqlite(code: -1, context: "\(error)")) }
                }
            }
            var results: [Result<Void, StoreError>] = []
            for await result in group { results.append(result) }
            return results
        }
        let winners = outcomes.filter { if case .success = $0 { true } else { false } }
        XCTAssertEqual(winners.count, 1)
        for case .failure(let error) in outcomes {
            guard case .keywordConflict = error else { return XCTFail("unexpected failure \(error)") }
        }
        let raw = try RawDatabase(url, readOnly: true)
        XCTAssertEqual(try raw.count("snippets"), 1)
        XCTAssertEqual(try raw.count("snippet_revisions"), 1)
    }

    // MARK: Delete, undo, purge

    func testDeleteTombstonesFreesKeywordAndRestoreBringsEverythingBack() async throws {
        let store = try openStore(at: try databaseURL())
        let original = try await store.create(makeSnippet(tags: ["t"]))
        clock.advance(by: 10)
        try await store.delete(id: original.id)

        let live = try await store.snippet(id: original.id)
        XCTAssertNil(live)
        let all = try await store.allSnippets()
        XCTAssertTrue(all.isEmpty)
        let deleted = try await store.deletedSnippets()
        XCTAssertEqual(deleted.map(\.snippet.id), [original.id])
        XCTAssertEqual(deleted.first?.deletedAt, clock.now)

        let reuse = try await store.create(makeSnippet(name: "Reuses keyword"))
        XCTAssertEqual(reuse.keyword, original.keyword, "a tombstone does not hold its keyword")
        try await store.delete(id: reuse.id)

        let restored = try await store.restore(id: original.id)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.tags, ["t"])
        XCTAssertEqual(restored.template, original.template)
        XCTAssertEqual(restored.revision, 3, "create 1, delete 2, restore 3")
        let afterRestore = try await store.deletedSnippets().map(\.snippet.id)
        XCTAssertEqual(afterRestore, [reuse.id])
    }

    func testRestoreIntoKeywordConflictFailsOrRestoresDisabledOnRequest() async throws {
        let store = try openStore(at: try databaseURL())
        let original = try await store.create(makeSnippet())
        try await store.delete(id: original.id)
        let holder = try await store.create(makeSnippet(name: "Holder"))

        await assertThrows(StoreError.keywordConflict(existingID: holder.id)) { _ = try await store.restore(id: original.id) }
        let stillDeleted = try await store.deletedSnippets().map(\.snippet.id)
        XCTAssertEqual(stillDeleted, [original.id], "a failed undo keeps the tombstone")

        let restored = try await store.restore(id: original.id, disablingOnKeywordConflict: true)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.keyword, original.keyword)
    }

    func testDeleteRestorePurgePreconditions() async throws {
        let store = try openStore(at: try databaseURL())
        let live = try await store.create(makeSnippet())
        await assertThrows(StoreError.notDeleted(id: live.id)) { _ = try await store.restore(id: live.id) }
        await assertThrows(StoreError.notDeleted(id: live.id)) { try await store.purge(id: live.id) }
        let unknown = UUID()
        await assertThrows(StoreError.notFound(id: unknown)) { try await store.delete(id: unknown) }
        try await store.delete(id: live.id)
        await assertThrows(StoreError.notFound(id: live.id)) { try await store.delete(id: live.id) }
        let tombstoneUpdate = live
        await assertThrows(StoreError.notFound(id: live.id)) { _ = try await store.update(tombstoneUpdate) }
    }

    func testPurgeRemovesRowTagsAndRevisionsPermanently() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let snippet = try await store.create(makeSnippet(tags: ["a"]))
        try await store.delete(id: snippet.id)
        try await store.purge(id: snippet.id)
        let raw = try RawDatabase(url, readOnly: true)
        XCTAssertEqual(try raw.count("snippets"), 0)
        XCTAssertEqual(try raw.count("snippet_tags"), 0)
        XCTAssertEqual(try raw.count("snippet_revisions"), 0)
        await assertThrows(StoreError.notFound(id: snippet.id)) { _ = try await store.restore(id: snippet.id) }
    }

    func testExpiredTombstonesArePurgedAfterRetentionOnly() async throws {
        let store = try openStore(at: try databaseURL())
        let old = try await store.create(makeSnippet(keyword: nil))
        try await store.delete(id: old.id)
        clock.advance(by: SnippetStore.tombstoneRetention - 1)
        let recent = try await store.create(makeSnippet(keyword: nil))
        try await store.delete(id: recent.id)
        let early = try await store.purgeExpiredTombstones()
        XCTAssertEqual(early, 0, "nothing is older than the retention yet")
        clock.advance(by: 2)
        let purged = try await store.purgeExpiredTombstones()
        XCTAssertEqual(purged, 1)
        let remaining = try await store.deletedSnippets().map(\.snippet.id)
        XCTAssertEqual(remaining, [recent.id])
        let live = try await store.create(makeSnippet(keyword: nil))
        let liveAfter = try await store.purgeExpiredTombstones()
        XCTAssertEqual(liveAfter, 0)
        let stillThere = try await store.snippet(id: live.id)
        XCTAssertNotNil(stillThere, "live snippets are never purged")
    }

    // MARK: Pin, usage, revisions, tags

    func testPinnedSnippetsListFirstThenByName() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(name: "bravo", keyword: nil))
        _ = try await store.create(makeSnippet(name: "Alpha", keyword: nil))
        let zulu = try await store.create(makeSnippet(name: "Zulu", keyword: nil))
        let pinned = try await store.setPinned(true, id: zulu.id)
        XCTAssertTrue(pinned.pinned)
        XCTAssertEqual(pinned.revision, 2)
        let names = try await store.allSnippets().map(\.name)
        XCTAssertEqual(names, ["Zulu", "Alpha", "bravo"])
        let unpinned = try await store.setPinned(false, id: zulu.id)
        XCTAssertFalse(unpinned.pinned)
    }

    func testRecordUsageTracksLastUsedAndCountWithoutTouchingRevision() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet(name: "A", keyword: nil))
        let b = try await store.create(makeSnippet(name: "B", keyword: nil))
        let never = try await store.usage(of: a.id)
        XCTAssertEqual(never, SnippetUsage(lastUsedAt: nil, useCount: 0))

        clock.advance(by: 5)
        try await store.recordUsage(id: a.id)
        let aFirstUse = clock.now
        clock.advance(by: 5)
        try await store.recordUsage(id: b.id)
        clock.advance(by: 5)
        try await store.recordUsage(id: a.id)

        let usage = try await store.usage(of: a.id)
        XCTAssertEqual(usage, SnippetUsage(lastUsedAt: clock.now, useCount: 2))
        XCTAssertNotEqual(usage.lastUsedAt, aFirstUse)
        let recent = try await store.recentlyUsed(limit: 10).map(\.id)
        XCTAssertEqual(recent, [a.id, b.id])
        let limited = try await store.recentlyUsed(limit: 1).map(\.id)
        XCTAssertEqual(limited, [a.id])
        let fetched = try await store.snippet(id: a.id)
        XCTAssertEqual(fetched?.revision, 1, "usage is device-local and not a content revision")
        XCTAssertEqual(fetched?.lastUsedAt, clock.now)

        var edited = try XCTUnwrap(fetched)
        edited.lastUsedAt = nil
        let updated = try await store.update(edited)
        XCTAssertEqual(updated.lastUsedAt, clock.now, "update does not overwrite usage")
        let kept = try await store.usage(of: a.id)
        XCTAssertEqual(kept.useCount, 2)
    }

    func testUsageOnUnknownSnippetFails() async throws {
        let store = try openStore(at: try databaseURL())
        let unknown = UUID()
        await assertThrows(StoreError.notFound(id: unknown)) { try await store.recordUsage(id: unknown) }
        await assertThrows(StoreError.notFound(id: unknown)) { _ = try await store.usage(of: unknown) }
    }

    func testRevisionsKeepSnapshotsNewestFirst() async throws {
        let store = try openStore(at: try databaseURL())
        var snippet = try await store.create(makeSnippet(name: "v1"))
        for name in ["v2", "v3"] {
            clock.advance(by: 1)
            snippet.name = name
            snippet = try await store.update(snippet)
        }
        let revisions = try await store.revisions(of: snippet.id)
        XCTAssertEqual(revisions.map(\.revision), [3, 2, 1])
        XCTAssertEqual(revisions.map(\.snippet.name), ["v3", "v2", "v1"])
        XCTAssertEqual(revisions.first?.snippet, snippet)
    }

    func testRevisionHistoryIsBoundedAndKeepsTheNewest() async throws {
        let store = try openStore(at: try databaseURL())
        var snippet = try await store.create(makeSnippet(keyword: nil))
        for index in 0..<55 {
            snippet.name = "n\(index)"
            snippet = try await store.update(snippet)
        }
        let revisions = try await store.revisions(of: snippet.id)
        XCTAssertEqual(revisions.count, SnippetStore.maxRevisionsPerSnippet)
        XCTAssertEqual(revisions.first?.revision, 56)
        XCTAssertEqual(revisions.last?.revision, 56 - SnippetStore.maxRevisionsPerSnippet + 1)
        XCTAssertEqual(snippet.revision, 56, "pruning history never touches the live row")
    }

    func testTagsAreListedWithCountsAndFilterLiveSnippetsOnly() async throws {
        let store = try openStore(at: try databaseURL())
        let one = try await store.create(makeSnippet(name: "One", keyword: nil, tags: ["work", "mail"]))
        _ = try await store.create(makeSnippet(name: "Two", keyword: nil, tags: ["work"]))
        let gone = try await store.create(makeSnippet(name: "Gone", keyword: nil, tags: ["work", "old"]))
        try await store.delete(id: gone.id)

        let tags = try await store.tags()
        XCTAssertEqual(tags, [TagSummary(tag: "mail", count: 1), TagSummary(tag: "work", count: 2)])
        let work = try await store.allSnippets(tag: "work").map(\.name)
        XCTAssertEqual(work, ["One", "Two"])
        let none = try await store.allSnippets(tag: "old")
        XCTAssertTrue(none.isEmpty)

        var retagged = one
        retagged.tags = ["solo"]
        _ = try await store.update(retagged)
        let after = try await store.tags()
        XCTAssertEqual(after, [TagSummary(tag: "solo", count: 1), TagSummary(tag: "work", count: 1)])
    }

    func testClosedStoreRejectsFurtherUse() async throws {
        let store = try openStore(at: try databaseURL())
        await store.close()
        await assertThrows(StoreError.closed) { _ = try await store.allSnippets() }
    }
}
