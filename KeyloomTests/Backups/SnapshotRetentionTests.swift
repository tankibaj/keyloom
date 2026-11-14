import XCTest
@testable import Keyloom

final class SnapshotRetentionTests: SnapshotTestCase {
    /// One changed library per day for `days` days.
    private func takeDaily(_ manager: SnapshotManager, days: Int) async throws {
        for day in 1...days {
            _ = try await manager.takeDailyIfChanged(library(named: "day \(day)"))
            clock.advance(by: Self.day)
        }
    }

    func testThirtyDailySnapshotsAreAllKept() async throws {
        let (manager, _) = try makeManager()
        try await takeDaily(manager, days: 30)
        let daily = try await manager.list().filter { $0.kind == .daily }
        XCTAssertEqual(daily.count, 30)
    }

    func testThirtyFirstDailySnapshotPrunesTheOldestOnly() async throws {
        let (manager, _) = try makeManager()
        let first = clock.now
        try await takeDaily(manager, days: 31)
        let daily = try await manager.list().filter { $0.kind == .daily }
        XCTAssertEqual(daily.count, 30)
        XCTAssertFalse(daily.contains { $0.createdAt == first }, "day 1 is the one that fell off")
        let newest = try await manager.load(try XCTUnwrap(daily.first))
        XCTAssertEqual(newest.snippets.first?.name, "day 31")
        let oldest = try await manager.load(try XCTUnwrap(daily.last))
        XCTAssertEqual(oldest.snippets.first?.name, "day 2")
    }

    func testTenSafeguardSnapshotsAreKeptAndTheEleventhPrunesTheOldest() async throws {
        let (manager, _) = try makeManager()
        for number in 1...10 {
            _ = try await manager.takeSafeguard(number.isMultiple(of: 2) ? .preRestore : .preImport, snippets: library(named: "s\(number)"))
            clock.advance(by: 60)
        }
        var kept = try await manager.list()
        XCTAssertEqual(kept.count, 10)

        _ = try await manager.takeSafeguard(.preImport, snippets: library(named: "s11"))
        kept = try await manager.list()
        XCTAssertEqual(kept.count, 10, "pre-import and pre-restore snapshots share one budget of ten")
        let names = try await kept.asyncMap { try await manager.load($0).snippets.first?.name }
        XCTAssertEqual(names.first, "s11")
        XCTAssertEqual(names.last, "s2", "s1 was the oldest")
    }

    func testTheTwoRetentionBucketsDoNotEvictEachOther() async throws {
        let (manager, _) = try makeManager()
        try await takeDaily(manager, days: 30)
        for number in 1...11 {
            _ = try await manager.takeSafeguard(.preImport, snippets: library(named: "s\(number)"))
            clock.advance(by: 60)
        }
        let all = try await manager.list()
        XCTAssertEqual(all.filter { $0.kind == .daily }.count, 30)
        XCTAssertEqual(all.filter { $0.kind != .daily }.count, 10)
    }

    func testSeveralSnapshotsInTheSameSecondNeverOverwriteEachOther() async throws {
        let (manager, _) = try makeManager()
        for number in 1...3 { _ = try await manager.takeSafeguard(.preImport, snippets: library(named: "s\(number)")) }
        let kept = try await manager.list()
        XCTAssertEqual(kept.count, 3)
        let names = try await kept.asyncMap { try await manager.load($0).snippets.first?.name }
        XCTAssertEqual(names, ["s3", "s2", "s1"], "newest first, even within one second")
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
