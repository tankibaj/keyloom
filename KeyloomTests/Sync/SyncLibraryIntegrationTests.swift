import XCTest
@testable import Keyloom

/// The library and the sync controller share one store, so edits made through the library are queued for the
/// account that is syncing, and changes sync applies reach the library's snapshot and observers.
final class SyncLibraryIntegrationTests: SyncTestCase {
    private let account = "icloud:A"

    private func template(_ text: String) -> Document {
        Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal(text)])])])
    }

    func testEditsThroughTheLibraryWhileSyncIsOnAreQueuedForTheAccountWithoutARelaunch() async throws {
        let device = try makeDevice()
        let library = try await SnippetLibrary(store: device.store)
        let sharedStore = library.syncStore
        XCTAssertTrue(sharedStore === device.store, "one store, one connection")
        device.useController(onLibraryChanged: { await library.reloadAfterSync() })
        await device.enableSync()

        let created = try await library.create(name: "Through the library", icon: .symbol("star"), keyword: ";lib",
                                               template: template("hello"))
        let pending = try await device.store.pending(account: account)
        XCTAssertEqual(pending.map(\.recordID), [created.id], "journaled under the syncing account, not under local")
        let local = try await device.store.pending(account: SnippetStore.localSyncAccount)
        XCTAssertEqual(local, [])
        let outgoing = try await device.store.nextOutgoing(account: account, limit: 10)
        XCTAssertEqual(outgoing.map(\.recordID), [created.id])

        await device.controller.localChangesCommitted()
        XCTAssertEqual(cloud.snippets(account: account)[created.id]?.name, "Through the library")
    }

    func testChangesSyncAppliesReachTheLibrarySnapshotAndObservers() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let library = try await SnippetLibrary(store: second.store)
        second.useController(onLibraryChanged: { await library.reloadAfterSync() })
        let stream = library.changes
        let observed = Task { () -> [LibraryChange] in
            var seen: [LibraryChange] = []
            for await change in stream { seen.append(change) }
            return seen
        }
        await first.enableSync()
        await second.enableSync()
        let arriving = try await first.store.create(makeSnippet(name: "From the other Mac", keyword: ";om"))
        await first.sync()
        await second.sync()

        let inSnapshot = await library.snippet(id: arriving.id)
        XCTAssertEqual(inSnapshot?.name, "From the other Mac", "the in-memory snapshot and indexes were reloaded")
        await library.close()
        let seen = await observed.value
        XCTAssertEqual(seen, [.remoteChangesApplied])
    }
}
