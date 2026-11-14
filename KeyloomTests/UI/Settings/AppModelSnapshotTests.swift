import XCTest
@testable import Keyloom

@MainActor
final class AppModelSnapshotTests: LibraryUITestCase {
    func testOpenTakesTheDailySnapshotOfTheLoadedLibrary() async throws {
        let directory = try makeDirectory()
        let seeded = try await openLibrary(at: directory)
        try await seed(seeded, "Persisted")
        await seeded.close()

        let model = AppModel(dataDirectory: directory)
        await model.open()
        let listed = try await model.snapshots.list()
        XCTAssertEqual(listed.map(\.kind), [.daily])
        XCTAssertNil(model.snapshotError)
    }

    func testSnapshotsLiveBesideTheLibraryAndTheStoreWritesItsMigrationCopiesInsideThem() throws {
        let directory = try makeDirectory()
        let model = AppModel(dataDirectory: directory)
        XCTAssertEqual(model.snapshots.directory, DataLocation.snapshotDirectory(in: directory))
        XCTAssertEqual(model.snapshots.migrationBackupDirectory.deletingLastPathComponent(), model.snapshots.directory)
    }

    func testADayChangeTakesANewDailySnapshotAndAFailureIsReportedWithoutBlocking() async throws {
        let center = NotificationCenter()
        let library = try await openTestLibrary()
        try await seed(library, "Alpha")
        let manager = SnapshotManager(directory: try makeDirectory().appendingPathComponent("snaps"), now: { [clock] in clock.now })
        let model = AppModel(dataDirectory: try makeDirectory(), snapshots: manager, openLibrary: { _ in library })
        await model.open()
        model.observeDayChanges(center: center)
        var kinds = try await manager.list().map(\.kind)
        XCTAssertEqual(kinds, [.daily], "launch snapshot")

        try await seed(library, "Beta")
        clock.advance(by: 86_400)
        center.post(name: .NSCalendarDayChanged, object: nil)
        await model.pendingSnapshot?.value
        kinds = try await manager.list().map(\.kind)
        XCTAssertEqual(kinds, [.daily, .daily], "the new day's snapshot")
        XCTAssertNil(model.snapshotError)

        try await seed(library, "Gamma")
        clock.advance(by: 86_400)
        try? FileManager.default.removeItem(at: manager.directory)
        try Data().write(to: manager.directory)  // the folder is now a file: the next write fails
        center.post(name: .NSSystemClockDidChange, object: nil)
        await model.pendingSnapshot?.value
        XCTAssertNotNil(model.snapshotError)
        guard case .ready = model.phase else { return XCTFail("a failed snapshot must not close the library") }
    }

    func testAFailedSnapshotIsReportedAndTheLibraryStillOpens() async throws {
        let blocker = try makeDirectory().appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let manager = SnapshotManager(directory: blocker.appendingPathComponent("inside"), now: { [clock] in clock.now })
        let model = AppModel(dataDirectory: try makeDirectory(), snapshots: manager,
                             openLibrary: { [self] in try await openLibrary(at: $0) })
        await model.open()
        guard case .ready = model.phase else { return XCTFail("the library must open without a snapshot") }
        XCTAssertNotNil(model.snapshotError)
    }
}
