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
