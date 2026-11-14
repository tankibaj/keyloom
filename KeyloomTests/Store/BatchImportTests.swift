import XCTest
@testable import Keyloom

final class BatchImportTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    func testBatchStoresEverySnippetAsGivenAndJournalsOneUpsertEach() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let a = makeRichSnippet(id: ids.next(), keyword: ";a")
        var b = makeSnippet(id: ids.next(), name: "B", keyword: ";b", tags: ["x"])
        b.revision = 5
        let result = try await store.importBatch([a, b])

        var expectedA = a
        expectedA.lastUsedAt = nil
        var expectedB = b
        expectedB.lastUsedAt = nil
        XCTAssertEqual(result.stored, [expectedA, expectedB], "revision, flags and dates are kept; usage is device-local")
        XCTAssertEqual(result.disabledForKeywordConflict, [])
        let loaded = try await store.allSnippets()
        XCTAssertEqual(Set(loaded.map(\.id)), [a.id, b.id])
        let outbox = try await store.pending()
        XCTAssertEqual(outbox.map(\.recordID), [a.id, b.id])
        XCTAssertEqual(outbox.map(\.revision), [7, 5])
        XCTAssertEqual(outbox.map(\.operation), [.upsert, .upsert])
        let history = try await store.revisions(of: b.id)
        XCTAssertEqual(history.map(\.revision), [5])
    }

    func testAFailureMidBatchRollsBackSnippetsTagsHistoryAndOutbox() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        _ = try await store.create(makeSnippet(id: ids.next(), name: "Existing", keyword: ";e"))
        let raw = try RawDatabase(url)
        try raw.execute("""
        CREATE TRIGGER fail_boom BEFORE INSERT ON snippets WHEN NEW.name = 'boom' BEGIN SELECT RAISE(ABORT, 'injected'); END;
        """)
        let before = (try raw.count("snippets"), try raw.count("snippet_tags"), try raw.count("snippet_revisions"), try raw.count("sync_outbox"))

        let batch = [makeSnippet(id: ids.next(), name: "ok1", keyword: ";1", tags: ["t"]),
                     makeSnippet(id: ids.next(), name: "ok2", keyword: ";2", tags: ["t"]),
                     makeSnippet(id: ids.next(), name: "boom", keyword: ";3", tags: ["t"])]
        do {
            _ = try await store.importBatch(batch)
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
        let after = (try raw.count("snippets"), try raw.count("snippet_tags"), try raw.count("snippet_revisions"), try raw.count("sync_outbox"))
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
        XCTAssertEqual(before.3, after.3)
        let names = try await store.allSnippets().map(\.name)
        XCTAssertEqual(names, ["Existing"])
    }

    func testInvalidEntryFailsTheWholeBatchBeforeAnyWrite() async throws {
        let store = try openStore(at: try databaseURL())
        let good = makeSnippet(id: ids.next(), name: "Good", keyword: ";g")
        let bad = makeSnippet(id: ids.next(), name: "   ", keyword: ";b")
        do {
            _ = try await store.importBatch([good, bad])
            XCTFail("expected a validation error")
        } catch {
            XCTAssertEqual(error as? KeyloomError, .invalidSnippet(field: "name", reason: "must not be blank"))
        }
        let all = try await store.allSnippets()
        let outbox = try await store.pending()
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(outbox.isEmpty)
    }

    func testConflictingKeywordIsStoredDisabledAgainstLiveEnabledSnippetsAndEarlierBatchEntries() async throws {
        let store = try openStore(at: try databaseURL())
        let owner = try await store.create(makeSnippet(id: ids.next(), name: "Owner", keyword: ";hi"))
        let clash = makeSnippet(id: ids.next(), name: "Clash", keyword: ";hi")
        let first = makeSnippet(id: ids.next(), name: "First", keyword: ";new")
        let second = makeSnippet(id: ids.next(), name: "Second", keyword: ";new")
        let result = try await store.importBatch([clash, first, second])

        XCTAssertEqual(result.disabledForKeywordConflict, [clash.id, second.id])
        XCTAssertEqual(result.stored.map(\.enabled), [false, true, false])
        XCTAssertEqual(result.stored[0].keyword, ";hi")
        let live = try await store.snippet(id: owner.id)
        XCTAssertEqual(live?.enabled, true)
    }

    func testKeywordIsStoredInComposedForm() async throws {
        let store = try openStore(at: try databaseURL())
        let result = try await store.importBatch([makeSnippet(id: ids.next(), keyword: "e\u{0301}x")])
        XCTAssertEqual(result.stored.first?.keyword, "\u{00E9}x")
        let clash = try await store.importBatch([makeSnippet(id: ids.next(), name: "Other", keyword: "\u{00E9}x")])
        XCTAssertEqual(clash.stored.first?.enabled, false)
    }

    func testIdOfATrashedOrExistingRowGetsAFreshIdInsteadOfFailing() async throws {
        let store = try openStore(at: try databaseURL())
        let trashed = try await store.create(makeSnippet(id: ids.next(), name: "Gone", keyword: nil))
        try await store.delete(id: trashed.id)
        let live = try await store.create(makeSnippet(id: ids.next(), name: "Live", keyword: nil))
        let result = try await store.importBatch([makeSnippet(id: trashed.id, name: "Imported 1", keyword: nil),
                                                  makeSnippet(id: live.id, name: "Imported 2", keyword: nil)])
        XCTAssertEqual(result.stored.count, 2)
        XCTAssertFalse(result.stored.map(\.id).contains(trashed.id) || result.stored.map(\.id).contains(live.id))
        let deleted = try await store.deletedSnippets()
        XCTAssertEqual(deleted.map(\.snippet.name), ["Gone"], "the trashed row is untouched")
        let liveNames = try await store.allSnippets().map(\.name)
        XCTAssertEqual(Set(liveNames), ["Live", "Imported 1", "Imported 2"])
    }

    func testEmptyBatchChangesNothing() async throws {
        let store = try openStore(at: try databaseURL())
        let result = try await store.importBatch([])
        XCTAssertEqual(result.stored, [])
        let outbox = try await store.pending()
        XCTAssertTrue(outbox.isEmpty)
    }
}
