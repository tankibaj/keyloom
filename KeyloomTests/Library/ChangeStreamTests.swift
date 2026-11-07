import XCTest
@testable import Keyloom

@MainActor
final class ChangeStreamTests: LibraryUITestCase {
    func testASubscriberThatWasCancelledDoesNotEndLaterSubscribers() async throws {
        let library = try await openTestLibrary()
        let first = library.changes
        let reader = Task { for await _ in first {} }
        reader.cancel()
        await reader.value

        let second = library.changes
        let created = try await seed(library, "After the window closed")
        var iterator = second.makeAsyncIterator()
        let change = await iterator.next()
        XCTAssertEqual(change, .created(created.id))
    }

    func testEverySubscriberSeesEveryChange() async throws {
        let library = try await openTestLibrary()
        let one = library.changes
        let two = library.changes
        let created = try await seed(library, "Shared")
        _ = try await library.setPinned(true, id: created.id)
        var first = one.makeAsyncIterator()
        var second = two.makeAsyncIterator()
        let seenByFirst = [await first.next(), await first.next()]
        let seenBySecond = [await second.next(), await second.next()]
        XCTAssertEqual(seenByFirst, [.created(created.id), .updated(created.id)])
        XCTAssertEqual(seenBySecond, seenByFirst)
    }

    func testRemoteChangesReachEverySubscriber() async throws {
        let library = try await openTestLibrary()
        let one = library.changes
        let two = library.changes
        await library.reloadAfterSync()
        var first = one.makeAsyncIterator()
        var second = two.makeAsyncIterator()
        let seenByFirst = await first.next()
        let seenBySecond = await second.next()
        XCTAssertEqual(seenByFirst, .remoteChangesApplied)
        XCTAssertEqual(seenBySecond, .remoteChangesApplied)
    }

    func testClosingFinishesEveryStreamIncludingOnesOpenedAfterwards() async throws {
        let library = try await openTestLibrary()
        let open = library.changes
        await library.close()
        var iterator = open.makeAsyncIterator()
        let ended = await iterator.next()
        XCTAssertNil(ended)
        var late = library.changes.makeAsyncIterator()
        let lateEnd = await late.next()
        XCTAssertNil(lateEnd, "A subscriber after close ends at once instead of waiting forever")
    }
}
