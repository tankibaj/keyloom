import XCTest
@testable import Keyloom

final class SnapshotManagerTests: SnapshotTestCase {
    private struct Boom: Error {}

    // MARK: Changed days only

    func testFirstCallSnapshotsThenOnlyAChangedDayDoes() async throws {
        let (manager, _) = try makeManager()
        let first = try await manager.takeDailyIfChanged(library())
        XCTAssertEqual(first?.kind, .daily)

        clock.advance(by: Self.day)
        let unchanged = try await manager.takeDailyIfChanged(library())
        XCTAssertNil(unchanged, "same content as the last snapshot")

        clock.advance(by: Self.day)
        let changed = try await manager.takeDailyIfChanged(library(named: "edited"))
        XCTAssertNotNil(changed)
        let listed = try await manager.list()
        XCTAssertEqual(listed.count, 2)
    }

    func testAtMostOneDailySnapshotPerCalendarDay() async throws {
        let (manager, _) = try makeManager()
        _ = try await manager.takeDailyIfChanged(library())
        clock.advance(by: 60)
        let sameDay = try await manager.takeDailyIfChanged(library(named: "edited"))
        XCTAssertNil(sameDay)
    }

    func testDayBoundaryFollowsTheInjectedCalendar() async throws {
        // The fake clock starts at 2023-11-14 22:13:20 UTC; move to 23:59:59, one second before the next UTC day.
        clock.advance(by: 6_399)
        let (manager, _) = try makeManager()
        _ = try await manager.takeDailyIfChanged(library())
        clock.advance(by: 1)
        let nextDay = try await manager.takeDailyIfChanged(library(named: "edited"))
        XCTAssertNotNil(nextDay)
    }

    func testUsageAndOrderDoNotCountAsChanges() async throws {
        let (manager, _) = try makeManager()
        let a = makeSnippet(id: ids.next(), name: "A", keyword: ";a")
        let b = makeSnippet(id: ids.next(), name: "B", keyword: ";b")
        _ = try await manager.takeDailyIfChanged([a, b])
        clock.advance(by: Self.day)
        var used = a
        used.lastUsedAt = clock.now
        let result = try await manager.takeDailyIfChanged([b, used])
        XCTAssertNil(result)
    }

    func testARevisionBumpCountsAsAChange() async throws {
        let (manager, _) = try makeManager()
        let a = makeSnippet(id: ids.next(), name: "A", keyword: ";a")
        _ = try await manager.takeDailyIfChanged([a])
        clock.advance(by: Self.day)
        var edited = a
        edited.revision = 2
        let result = try await manager.takeDailyIfChanged([edited])
        XCTAssertNotNil(result)
    }

    func testAnUnreadableLastSnapshotDoesNotStopTheNextOne() async throws {
        let (manager, directory) = try makeManager()
        let first = try await manager.takeDailyIfChanged(library())
        try Data("garbage".utf8).write(to: try XCTUnwrap(first).url)
        clock.advance(by: Self.day)
        let next = try await manager.takeDailyIfChanged(library())
        XCTAssertNotNil(next)
        XCTAssertEqual(try files(in: directory).count, 2)
    }

    func testSafeguardSnapshotsAreAlwaysTakenEvenWhenUnchanged() async throws {
        let (manager, _) = try makeManager()
        _ = try await manager.takeDailyIfChanged(library())
        _ = try await manager.takeSafeguard(.preRestore, snippets: library())
        _ = try await manager.takeSafeguard(.preRestore, snippets: library())
        let listed = try await manager.list()
        XCTAssertEqual(listed.map(\.kind), [.preRestore, .preRestore, .daily])
    }

    // MARK: Atomic writes

    func testSnapshotIsOwnerOnlyAndLeavesNoTemporaryFile() async throws {
        let (manager, directory) = try makeManager()
        let info = try await manager.takeSafeguard(.preImport, snippets: library())
        let attributes = try FileManager.default.attributesOfItem(atPath: info.url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try files(in: directory), [info.url.lastPathComponent])
    }

    func testInterruptedWriteLeavesNoSnapshotAndKeepsTheOlderOnes() async throws {
        let (healthy, directory) = try makeManager()
        let older = try await healthy.takeSafeguard(.preImport, snippets: library(named: "older"))
        clock.advance(by: 60)

        let (failing, _) = try makeManager(directory: directory, beforePublish: { throw Boom() })
        do {
            _ = try await failing.takeSafeguard(.preImport, snippets: library(named: "newer"))
            XCTFail("expected the write to fail")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .writeFailed(context: "write"))
        }
        XCTAssertEqual(try files(in: directory), [older.url.lastPathComponent], "no partial or temporary file remains")
        let listed = try await healthy.list()
        XCTAssertEqual(listed, [older])
        let contents = try await healthy.load(older)
        XCTAssertEqual(contents.snippets.first?.name, "older")
    }

    func testAnInterruptedDailySnapshotIsRetriedTheSameDay() async throws {
        let (healthy, directory) = try makeManager()
        let (failing, _) = try makeManager(directory: directory, beforePublish: { throw Boom() })
        _ = try? await failing.takeDailyIfChanged(library())
        let retried = try await healthy.takeDailyIfChanged(library())
        XCTAssertNotNil(retried, "a failed attempt does not use up the day")
    }

    func testStaleTemporaryFileFromACrashIsIgnoredAndCleanedUp() async throws {
        let (manager, directory) = try makeManager()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("keyloom-daily-1700000000-1.keyloomsnap.partial")
        try Data("half a snapshot".utf8).write(to: stale)
        let before = try await manager.list()
        XCTAssertTrue(before.isEmpty, "a partial file is never a snapshot")

        let info = try await manager.takeSafeguard(.preImport, snippets: library())
        XCTAssertEqual(try files(in: directory), [info.url.lastPathComponent])
    }

    func testDirectoryIsCreatedOwnerOnlyWhenMissing() async throws {
        let (manager, directory) = try makeManager()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try await manager.takeSafeguard(.preImport, snippets: library())
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    // MARK: Unreadable and corrupt snapshots

    func testLoadRoundTripsTheLibrary() async throws {
        let (manager, _) = try makeManager()
        let rich = makeRichSnippet()
        let info = try await manager.takeSafeguard(.preRestore, snippets: [rich])
        let contents = try await manager.load(info)
        var expected = rich
        expected.lastUsedAt = nil
        XCTAssertEqual(contents.snippets, [expected])
        XCTAssertEqual(contents.info, info)
    }

    func testTruncatedGarbageAndTamperedSnapshotsAreRejectedAsCorrupt() async throws {
        let (manager, _) = try makeManager()
        let info = try await manager.takeSafeguard(.preRestore, snippets: library())
        let good = try Data(contentsOf: info.url)

        for broken in [good.prefix(good.count / 2), Data("garbage".utf8), Data()] {
            try Data(broken).write(to: info.url)
            do {
                _ = try await manager.load(info)
                XCTFail("expected a corrupt snapshot")
            } catch {
                XCTAssertEqual(error as? SnapshotError, .corrupt)
            }
        }
        // Valid JSON whose content no longer matches the fingerprint taken when it was written.
        var file = try jsonObject(good)
        var snippets = try XCTUnwrap(file["snippets"] as? [[String: Any]])
        snippets[0]["name"] = "tampered"
        file["snippets"] = snippets
        try jsonData(file).write(to: info.url)
        do {
            _ = try await manager.load(info)
            XCTFail("expected a corrupt snapshot")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .corrupt)
        }
    }

    func testSnapshotFromANewerFormatIsRefusedAsUnsupported() async throws {
        let (manager, _) = try makeManager()
        let info = try await manager.takeSafeguard(.preRestore, snippets: library())
        var file = try jsonObject(try Data(contentsOf: info.url))
        file["formatVersion"] = 2
        try jsonData(file).write(to: info.url)
        do {
            _ = try await manager.load(info)
            XCTFail("expected a version refusal")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .unsupportedVersion(found: 2, supported: 1))
        }
    }

    func testMissingSnapshotIsUnreadable() async throws {
        let (manager, _) = try makeManager()
        let info = try await manager.takeSafeguard(.preRestore, snippets: library())
        try FileManager.default.removeItem(at: info.url)
        do {
            _ = try await manager.load(info)
            XCTFail("expected an unreadable snapshot")
        } catch {
            XCTAssertEqual(error as? SnapshotError, .unreadable)
        }
    }

    func testListIgnoresForeignFiles() async throws {
        let (manager, directory) = try makeManager()
        let info = try await manager.takeSafeguard(.preRestore, snippets: library())
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("keyloom-bogus-12-1.keyloomsnap"))
        let listed = try await manager.list()
        XCTAssertEqual(listed, [info])
    }

    // MARK: Pre-migration safeguard

    func testPreMigrationBackupUsesTheStoresVerifiedCopyInsideTheSnapshotRoot() async throws {
        let (manager, directory) = try makeManager()
        let databaseURL = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        let store = try openStore(at: databaseURL, backupDirectory: manager.migrationBackupDirectory)
        _ = try await store.create(makeSnippet(id: ids.next(), name: "A", keyword: ";a"))

        let backup = try await manager.preMigrationBackup(of: store)
        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL, manager.migrationBackupDirectory.standardizedFileURL)
        XCTAssertTrue(backup.path.hasPrefix(directory.path))
        let copy = try RawDatabase(backup)
        XCTAssertEqual(try copy.count("snippets"), 1)
        XCTAssertEqual(try copy.text("PRAGMA quick_check"), "ok")
        let listed = try await manager.list()
        XCTAssertTrue(listed.isEmpty, "migration copies are not library snapshots")
    }
}
