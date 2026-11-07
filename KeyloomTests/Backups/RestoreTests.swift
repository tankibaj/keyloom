import XCTest
@testable import Keyloom

final class RestoreTests: SnapshotTestCase {
    private struct Fixture {
        let library: SnippetLibrary
        let snapshots: SnapshotManager
        let snapshotDirectory: URL
        let raw: RawDatabase
    }

    private func makeFixture() async throws -> Fixture {
        let directory = try makeDirectory()
        let database = directory.appendingPathComponent("keyloom.sqlite")
        let library = try await SnippetLibrary(url: database, backupDirectory: directory.appendingPathComponent("backups"),
                                               now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        let (manager, snapshotDirectory) = try makeManager(directory: directory.appendingPathComponent("snapshots"))
        return Fixture(library: library, snapshots: manager, snapshotDirectory: snapshotDirectory, raw: try RawDatabase(database))
    }

    private func create(_ library: SnippetLibrary, _ name: String, _ keyword: String?) async throws -> Snippet {
        try await library.create(name: name, icon: .symbol("x"), keyword: keyword, template: literalDocument(name))
    }

    func testDailySnapshotOfTheLibraryThenRestoreBringsBackTheOldState() async throws {
        let f = try await makeFixture()
        let a = try await create(f.library, "A", ";a")
        let b = try await create(f.library, "B", ";b")
        let snapshot = try required(try await f.library.takeDailySnapshot(using: f.snapshots))

        _ = try await f.library.rename(id: a.id, to: "A changed")
        try await f.library.delete(id: b.id)
        _ = try await create(f.library, "C", ";c")
        let queuedBefore = try await f.library.pendingSyncChanges().count

        let outcome = try await f.library.restore(from: snapshot, using: f.snapshots)

        let names = await f.library.allSnippets().map(\.name)
        XCTAssertEqual(Set(names), ["A", "B"])
        XCTAssertEqual(Set(outcome.updated), [a.id])
        XCTAssertEqual(Set(outcome.created), [b.id])
        XCTAssertEqual(outcome.deleted.count, 1)
        let queued = try await f.library.pendingSyncChanges()
        XCTAssertEqual(queued.count - queuedBefore, 3, "each resulting change is queued for sync")
        let matcher = f.library.keywordMatcher
        matcher.invalidate()
        XCTAssertEqual(matcher.feed(";b")?.snippetID, b.id, "the matcher sees the restored keyword")
        matcher.invalidate()
        XCTAssertNil(matcher.feed(";c"), "and no longer the removed one")
    }

    func testRestoreFirstTakesAPreRestoreSnapshotOfTheCurrentLibrary() async throws {
        let f = try await makeFixture()
        _ = try await create(f.library, "A", ";a")
        let snapshot = try required(try await f.library.takeDailySnapshot(using: f.snapshots))
        let extra = try await create(f.library, "Extra", ";x")

        _ = try await f.library.restore(from: snapshot, using: f.snapshots)

        let preRestore = try required(try await f.snapshots.list().first { $0.kind == .preRestore })
        let contents = try await f.snapshots.load(preRestore)
        XCTAssertTrue(contents.snippets.contains { $0.id == extra.id }, "what the restore replaced can be restored in turn")
    }

    func testCorruptSnapshotIsRejectedAndTheLibraryStaysUntouched() async throws {
        let f = try await makeFixture()
        _ = try await create(f.library, "A", ";a")
        let snapshot = try required(try await f.library.takeDailySnapshot(using: f.snapshots))
        _ = try await create(f.library, "B", ";b")
        try Data("not a snapshot".utf8).write(to: snapshot.url)

        let listBefore = await f.library.allSnippets()
        let rowsBefore = try f.raw.count("snippets")
        let outboxBefore = try f.raw.count("sync_outbox")
        let snapshotsBefore = try files(in: f.snapshotDirectory)

        do {
            _ = try await f.library.restore(from: snapshot, using: f.snapshots)
            XCTFail("expected a corrupt snapshot")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .corrupt)
        }
        let listAfter = await f.library.allSnippets()
        XCTAssertEqual(listBefore, listAfter)
        XCTAssertEqual(try f.raw.count("snippets"), rowsBefore)
        XCTAssertEqual(try f.raw.count("sync_outbox"), outboxBefore)
        XCTAssertEqual(try files(in: f.snapshotDirectory), snapshotsBefore, "no pre-restore snapshot for a restore that never started")
    }

    func testAFaultDuringRestoreRollsBackAndTheLibraryKeepsItsCurrentState() async throws {
        let f = try await makeFixture()
        let a = try await create(f.library, "A", ";a")
        let b = try await create(f.library, "B", ";b")
        let snapshot = try required(try await f.library.takeDailySnapshot(using: f.snapshots))
        _ = try await f.library.rename(id: a.id, to: "A later")
        _ = try await f.library.rename(id: b.id, to: "B later")
        let extra = try await create(f.library, "Extra", ";x")
        try f.raw.execute("CREATE TRIGGER fail_restore BEFORE UPDATE OF name ON snippets WHEN NEW.name = 'B' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        let listBefore = await f.library.allSnippets()
        let outboxBefore = try f.raw.count("sync_outbox")

        do {
            _ = try await f.library.restore(from: snapshot, using: f.snapshots)
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
        let listAfter = await f.library.allSnippets()
        XCTAssertEqual(listBefore, listAfter)
        XCTAssertEqual(try f.raw.count("sync_outbox"), outboxBefore)
        XCTAssertNotNil(listAfter.first { $0.id == extra.id })
        XCTAssertEqual(try f.raw.text("PRAGMA quick_check"), "ok")
    }

    func testDailySnapshotIsSkippedWhenNothingChanged() async throws {
        let f = try await makeFixture()
        _ = try await create(f.library, "A", ";a")
        let first = try await f.library.takeDailySnapshot(using: f.snapshots)
        clock.advance(by: Self.day)
        let second = try await f.library.takeDailySnapshot(using: f.snapshots)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }
}
