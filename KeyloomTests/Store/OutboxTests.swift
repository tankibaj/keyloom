import SQLite3
import XCTest
@testable import Keyloom

final class OutboxTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    // MARK: Journal rows

    func testEachLocalMutationAppendsOneRowWithOpRevisionAndRetryIdentity() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet(name: "A"))                    // upsert r1
        var edited = a
        edited.name = "A2"
        _ = try await store.update(edited)                                        // upsert r2
        _ = try await store.setPinned(true, id: a.id)                             // upsert r3
        try await store.delete(id: a.id)                                          // delete r4
        _ = try await store.restore(id: a.id)                                     // upsert r5
        let copy = try await store.duplicate(id: a.id)                            // upsert r1 of the copy
        try await store.recordUsage(id: a.id)                                     // device-local: no row

        let rows = try await store.pending()
        XCTAssertEqual(rows.map(\.operation), [.upsert, .upsert, .upsert, .delete, .upsert, .upsert])
        XCTAssertEqual(rows.map(\.revision), [1, 2, 3, 4, 5, 1])
        XCTAssertEqual(rows.map(\.recordID), [a.id, a.id, a.id, a.id, a.id, copy.id])
        XCTAssertEqual(Set(rows.map(\.account)), ["local"])
        XCTAssertEqual(Set(rows.map(\.retryID)).count, rows.count, "every intent has its own retry identity")
        XCTAssertTrue(rows.allSatisfy { $0.attempts == 0 && $0.lastAttemptAt == nil })
        XCTAssertEqual(rows.map(\.sequence), rows.map(\.sequence).sorted(), "oldest first")
    }

    func testPurgeAndRejectedWritesAddNoRows() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet())
        try await store.delete(id: a.id)
        let before = try await store.pending()
        try await store.purge(id: a.id)
        _ = try? await store.create(makeSnippet(name: " "))
        let after = try await store.pending()
        XCTAssertEqual(after, before, "the delete was journaled once, at delete time")
    }

    func testKeywordConflictRollsBackItsOutboxRowToo() async throws {
        let store = try openStore(at: try databaseURL())
        let first = try await store.create(makeSnippet())
        _ = try? await store.create(makeSnippet(name: "Rival"))
        let rows = try await store.pending()
        XCTAssertEqual(rows.map(\.recordID), [first.id])
    }

    // MARK: Queue API

    func testPendingIsOldestFirstAndLimited() async throws {
        let store = try openStore(at: try databaseURL())
        let snippets = try await [store.create(makeSnippet(name: "1", keyword: nil)),
                                  store.create(makeSnippet(name: "2", keyword: nil)),
                                  store.create(makeSnippet(name: "3", keyword: nil))]
        let all = try await store.pending()
        XCTAssertEqual(all.map(\.recordID), snippets.map(\.id))
        let firstTwo = try await store.pending(limit: 2)
        XCTAssertEqual(firstTwo.map(\.recordID), [snippets[0].id, snippets[1].id])
        let none = try await store.pending(limit: -1)
        XCTAssertTrue(none.isEmpty, "a negative limit is not SQLite's unlimited")
    }

    func testAcknowledgeRemovesTheRowOnce() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(keyword: nil))
        _ = try await store.create(makeSnippet(keyword: nil))
        let rows = try await store.pending()
        let acknowledged = try await store.acknowledge(retryID: rows[0].retryID)
        XCTAssertTrue(acknowledged)
        let again = try await store.acknowledge(retryID: rows[0].retryID)
        XCTAssertFalse(again)
        let remaining = try await store.pending()
        XCTAssertEqual(remaining, [rows[1]])
    }

    func testMarkFailedCountsAttemptsKeepsRetryIdentityAndKeepsTheRow() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet())
        let original = try await store.pending()[0]
        clock.advance(by: 30)
        let marked = try await store.markFailed(retryID: original.retryID)
        XCTAssertTrue(marked)
        _ = try await store.markFailed(retryID: original.retryID)
        let row = try await store.pending()[0]
        XCTAssertEqual(row.attempts, 2)
        XCTAssertEqual(row.lastAttemptAt, clock.now)
        XCTAssertEqual(row.retryID, original.retryID)
        XCTAssertEqual(row.sequence, original.sequence)
        let unknown = try await store.markFailed(retryID: UUID())
        XCTAssertFalse(unknown)
    }

    func testQueueSurvivesReopen() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        _ = try await store.create(makeSnippet())
        let marked = try await store.pending()[0]
        _ = try await store.markFailed(retryID: marked.retryID)
        let expected = try await store.pending()
        await store.close()
        let reopened = try openStore(at: url)
        let after = try await reopened.pending()
        XCTAssertEqual(after, expected)
    }

    // MARK: Account namespace

    func testOneAccountsOutboxIsNeverVisibleOrChangeableFromAnother() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        _ = try await store.create(makeSnippet(name: "local one", keyword: nil))
        try await store.setSyncAccount("acct-A")
        _ = try await store.create(makeSnippet(name: "A one", keyword: nil))

        let current = await store.syncAccount
        XCTAssertEqual(current, "acct-A")
        let forA = try await store.pending()
        XCTAssertEqual(forA.map(\.account), ["acct-A"])
        let forLocal = try await store.pending(account: "local")
        XCTAssertEqual(forLocal.map(\.account), ["local"])
        let forB = try await store.pending(account: "acct-B")
        XCTAssertTrue(forB.isEmpty)

        let localRow = forLocal[0]
        let ackFromWrongAccount = try await store.acknowledge(retryID: localRow.retryID)
        XCTAssertFalse(ackFromWrongAccount, "acct-A cannot acknowledge a local row")
        let failFromWrongAccount = try await store.markFailed(retryID: localRow.retryID, account: "acct-B")
        XCTAssertFalse(failFromWrongAccount)
        let untouched = try await store.pending(account: "local")
        XCTAssertEqual(untouched, [localRow])
        let ackRight = try await store.acknowledge(retryID: localRow.retryID, account: "local")
        XCTAssertTrue(ackRight)
    }

    func testAccountDefaultsToLocalAndIsValidated() async throws {
        let store = try openStore(at: try databaseURL())
        let account = await store.syncAccount
        XCTAssertEqual(account, "local")
        await assertThrows(StoreError.invalidAccount) { try await store.setSyncAccount("  ") }
        await assertThrows(StoreError.invalidAccount) { try await store.setSyncAccount(String(repeating: "x", count: 257)) }
        let unchanged = await store.syncAccount
        XCTAssertEqual(unchanged, "local")
        XCTAssertThrowsError(try openStore(at: try databaseURL(), syncAccount: "")) { error in
            XCTAssertEqual(error as? StoreError, .invalidAccount)
        }
    }

    // MARK: Fault injection: failure after the row write, before commit

    /// Real database failures, installed through a second connection, at three points after the snippet
    /// row has been written: the history insert, the outbox insert, and COMMIT itself (deferred constraint).
    private enum Fault: CaseIterable {
        case revisionInsert, outboxInsert, commit

        var install: String {
            switch self {
            case .revisionInsert:
                "CREATE TRIGGER fault BEFORE INSERT ON snippet_revisions BEGIN SELECT RAISE(ABORT, 'injected'); END"
            case .outboxInsert:
                "CREATE TRIGGER fault BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END"
            case .commit:
                """
                CREATE TABLE fk_parent (id INTEGER PRIMARY KEY);
                CREATE TABLE fk_child (parent INTEGER REFERENCES fk_parent (id) DEFERRABLE INITIALLY DEFERRED);
                CREATE TRIGGER fault AFTER INSERT ON sync_outbox BEGIN INSERT INTO fk_child (parent) VALUES (1); END
                """
            }
        }
    }

    private struct Snapshot: Equatable {
        let counts: [Int]
        let live: [Snippet]
        let deleted: [DeletedSnippet]
        let pending: [OutboxEntry]
    }

    private func snapshot(_ store: SnippetStore, _ raw: RawDatabase) async throws -> Snapshot {
        let counts = try ["snippets", "snippet_tags", "snippet_revisions", "sync_outbox"].map(raw.count)
        return try await Snapshot(counts: counts, live: store.allSnippets(), deleted: store.deletedSnippets(),
                                  pending: store.pending())
    }

    private func assertNoOrphans(_ raw: RawDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try raw.int("SELECT count(*) FROM sync_outbox WHERE record_id NOT IN (SELECT id FROM snippets)"), 0,
                       "outbox row without a snippet", file: file, line: line)
        XCTAssertEqual(try raw.int("SELECT count(*) FROM snippets WHERE id NOT IN (SELECT record_id FROM sync_outbox)"), 0,
                       "snippet row without an outbox row", file: file, line: line)
        XCTAssertEqual(try raw.int("SELECT count(*) FROM snippet_revisions WHERE snippet_id NOT IN (SELECT id FROM snippets)"), 0,
                       file: file, line: line)
    }

    func testFailureAfterTheRowWriteRollsBackEverythingForEveryMutation() async throws {
        for fault in Fault.allCases {
            let url = try databaseURL()
            let store = try openStore(at: url)
            let live = try await store.create(makeSnippet(name: "Live", keyword: ";live", tags: ["t"]))
            let trashed = try await store.create(makeSnippet(name: "Trashed", keyword: nil))
            try await store.delete(id: trashed.id)
            let raw = try RawDatabase(url)
            let before = try await snapshot(store, raw)
            try raw.execute(fault.install)

            var edited = live
            edited.name = "Changed"
            edited.tags = ["z"]
            let fresh = makeSnippet(name: "Fresh", keyword: ";fresh", tags: ["x"])
            let mutations: [(String, () async throws -> Void)] = [
                ("create", { _ = try await store.create(fresh) }),
                ("update", { _ = try await store.update(edited) }),
                ("pin", { _ = try await store.setPinned(true, id: live.id) }),
                ("delete", { try await store.delete(id: live.id) }),
                ("restore", { _ = try await store.restore(id: trashed.id) }),
                ("duplicate", { _ = try await store.duplicate(id: live.id) }),
            ]
            for (name, mutate) in mutations {
                // A delete writes no history snapshot, so that fault point is not on its path.
                if name == "delete", fault == .revisionInsert { continue }
                do {
                    try await mutate()
                    XCTFail("\(name) should fail under \(fault)")
                } catch StoreError.sqlite(let code, _) {
                    XCTAssertEqual(code & 0xFF, SQLITE_CONSTRAINT, "\(name) under \(fault)")
                }
                let after = try await snapshot(store, raw)
                XCTAssertEqual(after, before, "\(name) under \(fault) left a partial write")
                try assertNoOrphans(raw)
            }

            // The connection is not stuck in a transaction: once the fault is gone writes work again.
            try raw.execute("DROP TRIGGER fault")
            let recovered = try await store.create(fresh)
            let rows = try await store.pending()
            XCTAssertEqual(rows.count, before.pending.count + 1)
            XCTAssertEqual(rows.last?.recordID, recovered.id)
            try assertNoOrphans(raw)

            // And a reopened file shows the same committed state.
            await store.close()
            let reopened = try openStore(at: url)
            let reopenedLive = try await reopened.allSnippets().map(\.id)
            XCTAssertEqual(Set(reopenedLive), [live.id, recovered.id])
            try assertNoOrphans(raw)
        }
    }
}
