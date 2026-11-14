import XCTest
@testable import Keyloom

/// The store side of "records a newer Keyloom wrote": the per-account marker, the restart of a fetch and the
/// hold on pushing those records. Real SQLite file, nothing mocked.
final class NewerSchemaMarkerTests: StoreTestCase {
    private let accountA = "icloud:A"
    private let accountB = "icloud:B"

    private func makeStore() throws -> SnippetStore {
        try openStore(at: try makeDirectory().appendingPathComponent("keyloom.sqlite"))
    }

    func testTheMarkerKeepsTheHighestVersionAndTheUnionOfRecords() async throws {
        let store = try makeStore()
        let (one, two) = (UUID(), UUID())
        try await store.updateNewerSchemaMarker(seen: [one: 3], resolved: [], account: accountA)
        let merged = try await store.updateNewerSchemaMarker(seen: [two: 2], resolved: [], account: accountA)
        XCTAssertEqual(merged, NewerSchemaMarker(version: 3, recordIDs: [one, two]))
        let stored = try await store.newerSchemaMarker(account: accountA)
        XCTAssertEqual(stored, merged)

        let remaining = try await store.updateNewerSchemaMarker(seen: [:], resolved: [one], account: accountA)
        XCTAssertEqual(remaining, NewerSchemaMarker(version: 3, recordIDs: [two]))
        let none = try await store.updateNewerSchemaMarker(seen: [:], resolved: [two], account: accountA)
        XCTAssertNil(none)
        let gone = try await store.newerSchemaMarker(account: accountA)
        XCTAssertNil(gone)
    }

    func testRestartingAFetchDropsOneAccountsTokenAndMarkerOnly() async throws {
        let store = try makeStore()
        for account in [accountA, accountB] {
            try await store.saveSyncEngineState(Data("token".utf8), account: account)
            try await store.updateNewerSchemaMarker(seen: [UUID(): 2], resolved: [], account: account)
        }
        try await store.restartFetchAfterUpgrade(account: accountA)

        let stateA = try await store.syncEngineState(account: accountA)
        let markerA = try await store.newerSchemaMarker(account: accountA)
        let stateB = try await store.syncEngineState(account: accountB)
        let markerB = try await store.newerSchemaMarker(account: accountB)
        XCTAssertNil(stateA)
        XCTAssertNil(markerA)
        XCTAssertEqual(stateB, Data("token".utf8))
        XCTAssertNotNil(markerB)
    }

    func testAnIcloudDataResetForgetsTheMarkerToo() async throws {
        let store = try makeStore()
        try await store.updateNewerSchemaMarker(seen: [UUID(): 2], resolved: [], account: accountA)
        try await store.resetSyncMetadata(account: accountA)
        let marker = try await store.newerSchemaMarker(account: accountA)
        XCTAssertNil(marker)
    }

    func testTheMarkerNeverShowsUpAsAnAccountsEngineState() async throws {
        let store = try makeStore()
        try await store.updateNewerSchemaMarker(seen: [UUID(): 2], resolved: [], account: accountA)
        let state = try await store.syncEngineState(account: accountA)
        XCTAssertNil(state)
    }

    func testHeldRecordsStayQueuedAndOthersAreStillOffered() async throws {
        let store = try makeStore()
        try await store.setSyncAccount(accountA)
        let held = try await store.create(makeSnippet(name: "Held", keyword: ";held"))
        let other = try await store.create(makeSnippet(name: "Other", keyword: ";other"))
        _ = try await store.prepareSync(account: accountA)

        let batch = try await store.nextOutgoingBatch(account: accountA, limit: 10, excluding: [held.id])
        XCTAssertEqual(batch.changes.map(\.recordID), [other.id])
        let queued = try await store.pending(account: accountA).map(\.recordID)
        XCTAssertTrue(queued.contains(held.id), "a held record's intents are not discarded")
        let released = try await store.nextOutgoingBatch(account: accountA, limit: 10)
        XCTAssertEqual(Set(released.changes.map(\.recordID)), [held.id, other.id])
    }
}
