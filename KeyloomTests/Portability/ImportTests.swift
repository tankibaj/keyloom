import XCTest
@testable import Keyloom

final class ImportTests: StoreTestCase {
    private struct Fixture {
        let library: SnippetLibrary
        let database: URL
        let snapshots: SnapshotManager
        let raw: RawDatabase
    }

    private func makeFixture() async throws -> Fixture {
        let directory = try makeDirectory()
        let database = directory.appendingPathComponent("keyloom.sqlite")
        let library = try await SnippetLibrary(url: database, backupDirectory: directory.appendingPathComponent("backups"),
                                               now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let snapshots = SnapshotManager(directory: directory.appendingPathComponent("snapshots"), now: { [clock] in clock.now }, calendar: calendar)
        return Fixture(library: library, database: database, snapshots: snapshots, raw: try RawDatabase(database))
    }

    private func raycast(_ records: [[String: String]]) throws -> Data { try jsonData(records) }

    func testAcceptedSetIsCommittedTogetherAndEveryDerivedIndexRefreshed() async throws {
        let f = try await makeFixture()
        let preview = try await f.library.previewImport(try raycast([
            ["name": "One", "text": "1", "keyword": ";one"], ["name": "Two", "text": "2", "keyword": ";two"],
            ["name": "Three", "text": "3"],
        ]))
        let outcome = try await f.library.commitImport(preview, snapshots: f.snapshots)

        XCTAssertEqual(outcome.imported.count, 3)
        let all = await f.library.allSnippets()
        XCTAssertEqual(Set(all.map(\.name)), ["One", "Two", "Three"])
        let matcher = f.library.keywordMatcher
        matcher.invalidate()
        XCTAssertEqual(matcher.feed(";one")?.snippetID, outcome.imported.first { $0.name == "One" }?.id)
        if case .results(let hits) = await f.library.search(query: "Three") { XCTAssertEqual(hits.count, 1) } else { XCTFail("search index is stale") }
        let queued = try await f.library.pendingSyncChanges()
        XCTAssertEqual(queued.map(\.operation), [.upsert, .upsert, .upsert])
    }

    func testConflictingImportIsKeptDisabledAndTheExistingSnippetKeepsTheKeyword() async throws {
        let f = try await makeFixture()
        let existing = try await f.library.create(name: "Mine", icon: .symbol("x"), keyword: ";hi", template: literalDocument("mine"))
        let preview = try await f.library.previewImport(try raycast([["name": "Theirs", "text": "theirs", "keyword": ";hi"]]))
        let outcome = try await f.library.commitImport(preview, snapshots: f.snapshots)

        XCTAssertEqual(outcome.disabledForKeywordConflict, outcome.imported.map(\.id))
        XCTAssertEqual(outcome.imported.first?.enabled, false)
        let matcher = f.library.keywordMatcher
        matcher.invalidate()
        XCTAssertEqual(matcher.feed(";hi")?.snippetID, existing.id)
    }

    func testSelectionImportsOnlyTheChosenItems() async throws {
        let f = try await makeFixture()
        let preview = try await f.library.previewImport(try raycast([["name": "A", "text": "a"], ["name": "B", "text": "b"]]))
        let outcome = try await f.library.commitImport(preview, selecting: [1], snapshots: f.snapshots)
        XCTAssertEqual(outcome.imported.map(\.name), ["B"])
        let names = await f.library.allSnippets().map(\.name)
        XCTAssertEqual(names, ["B"])
    }

    func testSkippedDuplicatesWriteNothingAndTakeNoSnapshot() async throws {
        let f = try await makeFixture()
        _ = try await f.library.create(name: "A", icon: .symbol("x"), keyword: ";a", template: literalDocument("a"))
        let preview = try await f.library.previewImport(try raycast([["name": "A", "text": "a", "keyword": ";a"]]))
        let before = try await f.library.pendingSyncChanges()
        let outcome = try await f.library.commitImport(preview, snapshots: f.snapshots)
        let after = try await f.library.pendingSyncChanges()
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertEqual(before, after)
        let listed = try await f.snapshots.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testPreImportSnapshotHoldsThePreviousLibrary() async throws {
        let f = try await makeFixture()
        let original = try await f.library.create(name: "Old", icon: .symbol("x"), keyword: ";old", template: literalDocument("old"))
        let preview = try await f.library.previewImport(try raycast([["name": "New", "text": "n"]]))
        _ = try await f.library.commitImport(preview, snapshots: f.snapshots)

        let snapshot = try required(try await f.snapshots.list().first)
        XCTAssertEqual(snapshot.kind, .preImport)
        let contents = try await f.snapshots.load(snapshot)
        XCTAssertEqual(contents.snippets.map(\.id), [original.id])
    }

    func testMalformedFileLeavesSQLiteIntact() async throws {
        let f = try await makeFixture()
        _ = try await f.library.create(name: "A", icon: .symbol("x"), keyword: ";a", template: literalDocument("a"))
        let snippetsBefore = try f.raw.count("snippets")
        let outboxBefore = try f.raw.count("sync_outbox")
        let listBefore = await f.library.allSnippets()

        for bad in [Data(#"[{"name": "A", "text":"#.utf8), Data("garbage".utf8),
                    try jsonData(["format": "keyloom-snippets", "formatVersion": 99, "snippets": []])] {
            do {
                _ = try await f.library.previewImport(bad)
                XCTFail("expected a typed refusal")
            } catch {
                XCTAssertTrue(error is PortabilityError)
            }
        }
        XCTAssertEqual(try f.raw.count("snippets"), snippetsBefore)
        XCTAssertEqual(try f.raw.count("sync_outbox"), outboxBefore)
        XCTAssertEqual(try f.raw.text("PRAGMA quick_check"), "ok")
        let listAfter = await f.library.allSnippets()
        XCTAssertEqual(listBefore, listAfter)
    }

    func testAFaultDuringTheCommitRollsBackTheWholeSelectedSet() async throws {
        let f = try await makeFixture()
        _ = try await f.library.create(name: "A", icon: .symbol("x"), keyword: ";a", template: literalDocument("a"))
        try f.raw.execute("CREATE TRIGGER fail_boom BEFORE INSERT ON snippets WHEN NEW.name = 'boom' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        let preview = try await f.library.previewImport(try raycast([
            ["name": "ok1", "text": "1", "keyword": ";1"], ["name": "ok2", "text": "2"], ["name": "boom", "text": "3"],
        ]))
        let snippetsBefore = try f.raw.count("snippets")
        let outboxBefore = try f.raw.count("sync_outbox")
        let listBefore = await f.library.allSnippets()

        do {
            _ = try await f.library.commitImport(preview, snapshots: f.snapshots)
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
        XCTAssertEqual(try f.raw.count("snippets"), snippetsBefore)
        XCTAssertEqual(try f.raw.count("sync_outbox"), outboxBefore)
        let listAfter = await f.library.allSnippets()
        XCTAssertEqual(listBefore, listAfter)
        let matcher = f.library.keywordMatcher
        matcher.invalidate()
        XCTAssertNil(matcher.feed(";1"))
    }

    func testNativeExportImportsIntoAnotherLibraryWithEveryFieldButUsage() async throws {
        let source = try await makeFixture()
        let rich = makeRichSnippet()
        _ = try await source.library.create(rich)
        let data = try await source.library.exportNative()

        let target = try await makeFixture()
        let preview = try await target.library.previewImport(data)
        _ = try await target.library.commitImport(preview, snapshots: target.snapshots)
        let imported = await target.library.snippet(id: rich.id)
        var expected = rich
        expected.lastUsedAt = nil
        XCTAssertEqual(imported, expected)
    }

    func testRaycastExportOfTheLibraryReportsLoss() async throws {
        let f = try await makeFixture()
        _ = try await f.library.create(makeRichSnippet())
        let export = try await f.library.exportRaycast()
        XCTAssertEqual(export.losses.map(\.snippetID), [makeRichSnippet().id])
    }
}
