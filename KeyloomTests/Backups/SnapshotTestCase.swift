import Foundation
import XCTest
@testable import Keyloom

/// A snapshot manager on a temp directory, a fake clock and a UTC calendar, so "day" is the same everywhere.
class SnapshotTestCase: StoreTestCase {
    static let day: TimeInterval = 86_400

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func makeManager(directory: URL? = nil, beforePublish: @escaping @Sendable () throws -> Void = {}) throws -> (SnapshotManager, URL) {
        let url = try directory ?? makeDirectory().appendingPathComponent("snapshots")
        return (SnapshotManager(directory: url, now: { [clock] in clock.now }, calendar: calendar, beforePublish: beforePublish), url)
    }

    /// The file names that are visible to a directory listing, which is what survives a crash.
    func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func library(named name: String = "A") -> [Snippet] {
        // Fixed dates: the library's content must not change just because the fake clock moved.
        [Snippet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: name, icon: .symbol("x"), keyword: ";a",
                 template: literalDocument(name), createdAt: Date(timeIntervalSince1970: 1_600_000_000))]
    }
}
