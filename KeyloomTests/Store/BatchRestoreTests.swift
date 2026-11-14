import XCTest
@testable import Keyloom

final class BatchRestoreTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    func testRestoreRewritesChangedAddsMissingAndTrashesExtrasWithRevisionsMovingForward() async throws {
        let store = try openStore(at: try databaseURL())
        let kept = try await store.create(makeSnippet(id: ids.next(), name: "Kept", keyword: ";k"))
        let edited = try await store.create(makeSnippet(id: ids.next(), name: "Edited", keyword: ";e"))
        let removed = try await store.create(makeSnippet(id: ids.next(), name: "Removed", keyword: ";r"))
        let target = try await store.allSnippets()                              // the state to come back to
        var changed = edited
        changed.name = "Edited later"
        let later = try await store.update(changed)                             // revision 2
        try await store.delete(id: removed.id)
        let extra = try await store.create(makeSnippet(id: ids.next(), name: "Extra", keyword: ";x"))
        let outboxBefore = try await store.pending().count

        let result = try await store.restoreLibrary(to: target)

        XCTAssertEqual(Set(result.created), [removed.id])
        XCTAssertEqual(Set(result.updated), [edited.id])
        XCTAssertEqual(Set(result.deleted), [extra.id])
        let live = try await store.allSnippets()
        XCTAssertEqual(Set(live.map(\.name)), ["Kept", "Edited", "Removed"])
        let restoredEdited = try XCTUnwrap(live.first { $0.id == edited.id })
        XCTAssertEqual(restoredEdited.revision, later.revision + 1, "the store owns revisions: they only move forward")
        let trashed = try await store.deletedSnippets()
        XCTAssertEqual(trashed.map(\.snippet.id), [extra.id], "snippets added since are recoverable from the trash")

        let queued = try await store.pending().dropFirst(outboxBefore)
        XCTAssertEqual(queued.count, 3, "one intent per changed record, none for the untouched one")
        XCTAssertEqual(Set(queued.map(\.recordID)), [edited.id, removed.id, extra.id])
        XCTAssertEqual(queued.first { $0.recordID == extra.id }?.operation, .delete)
        XCTAssertFalse(queued.contains { $0.recordID == kept.id })
    }

    func testRestoringTheCurrentStateQueuesNothing() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a", tags: ["t"]))
        let current = try await store.allSnippets()
        let before = try await store.pending()
        let result = try await store.restoreLibrary(to: current)
        let after = try await store.pending()
        XCTAssertEqual(before, after)
        XCTAssertTrue(result.created.isEmpty && result.updated.isEmpty && result.deleted.isEmpty)
    }

    func testSnippetsSwappingKeywordsRestoreWithoutTransientConflict() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a"))
        let b = try await store.create(makeSnippet(id: ids.next(), name: "B", keyword: ";b"))
        let target = try await store.allSnippets()
        var swappedA = a
        swappedA.keyword = ";tmp"
        _ = try await store.update(swappedA)
        var swappedB = b
        swappedB.keyword = ";a"
        _ = try await store.update(swappedB)
        swappedA.keyword = ";b"
        _ = try await store.update(swappedA)
        _ = try await store.restoreLibrary(to: target)
        let live = try await store.allSnippets()
        XCTAssertEqual(live.first { $0.id == a.id }?.keyword, ";a")
        XCTAssertEqual(live.first { $0.id == b.id }?.keyword, ";b")
        XCTAssertTrue(live.allSatisfy(\.enabled))
    }

    func testRestoreBringsATrashedSnippetBackAndKeepsUsage() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a"))
        try await store.recordUsage(id: a.id)
        let target = try await store.allSnippets()
        try await store.delete(id: a.id)
        _ = try await store.restoreLibrary(to: target)
        let back = try await store.snippet(id: a.id)
        XCTAssertEqual(back?.name, "A")
        let usage = try await store.usage(of: a.id)
        XCTAssertEqual(usage.useCount, 1, "device-local usage is not part of a snapshot")
    }

    func testAFaultMidRestoreRollsEverythingBack() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let a = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a"))
        let b = try await store.create(makeSnippet(id: ids.next(), name: "B", keyword: ";b"))
        let target = try await store.allSnippets()
        var editedA = a
        editedA.name = "A2"
        _ = try await store.update(editedA)
        var editedB = b
        editedB.name = "B2"
        _ = try await store.update(editedB)
        let extra = try await store.create(makeSnippet(id: ids.next(), name: "Extra", keyword: ";x"))
        let raw = try RawDatabase(url)
        try raw.execute("""
        CREATE TRIGGER fail_restore BEFORE UPDATE OF name ON snippets WHEN NEW.name = 'B' BEGIN SELECT RAISE(ABORT, 'injected'); END;
        """)
        let rowsBefore = try raw.count("snippets")
        let outboxBefore = try await store.pending()
        let liveBefore = try await store.allSnippets()

        do {
            _ = try await store.restoreLibrary(to: target)
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
        let outboxAfter = try await store.pending()
        let liveAfter = try await store.allSnippets()
        XCTAssertEqual(try raw.count("snippets"), rowsBefore)
        XCTAssertEqual(outboxBefore, outboxAfter)
        XCTAssertEqual(liveBefore, liveAfter)
        XCTAssertTrue(liveAfter.contains { $0.id == extra.id }, "the extra snippet was not trashed")
    }

    func testDuplicateEnabledKeywordsInTheTargetKeepTheFirstAndDisableTheRest() async throws {
        let store = try openStore(at: try databaseURL())
        let first = makeSnippet(id: ids.next(), name: "First", keyword: ";same")
        let second = makeSnippet(id: ids.next(), name: "Second", keyword: ";same")
        let result = try await store.restoreLibrary(to: [first, second])
        XCTAssertEqual(result.disabledForKeywordConflict, [second.id])
        let live = try await store.allSnippets()
        XCTAssertEqual(live.first { $0.id == first.id }?.enabled, true)
        XCTAssertEqual(live.first { $0.id == second.id }?.enabled, false)
    }

    func testInvalidOrRepeatedTargetEntriesFailBeforeAnyWrite() async throws {
        let store = try openStore(at: try databaseURL())
        let a = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a"))
        let before = try await store.pending()
        do {
            _ = try await store.restoreLibrary(to: [makeSnippet(id: a.id, name: " ", keyword: ";a")])
            XCTFail("expected a validation error")
        } catch {
            XCTAssertEqual(error as? KeyloomError, .invalidSnippet(field: "name", reason: "must not be blank"))
        }
        do {
            _ = try await store.restoreLibrary(to: [a, a])
            XCTFail("expected a duplicate-id error")
        } catch {
            XCTAssertEqual(error as? StoreError, .alreadyExists(id: a.id))
        }
        let after = try await store.pending()
        let names = try await store.allSnippets().map(\.name)
        XCTAssertEqual(before, after)
        XCTAssertEqual(names, ["A"])
    }
}
