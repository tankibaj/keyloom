import CloudKit
import XCTest
@testable import Keyloom

/// Slice D1: private record transport, durable per-account state, retry-safe acknowledgements, crash replay and
/// tombstone propagation.
final class SyncReplayTests: SyncTestCase {
    private let account = "icloud:A"

    func testFirstSyncUploadsEachSnippetUnderItsStableRecordName() async throws {
        let device = try makeDevice()
        let snippet = try await device.store.create(makeSnippet(name: "Stable", keyword: ";st", tags: ["a", "b"], text: "Grüße"))
        await device.enableSync()

        XCTAssertEqual(cloud.recordID(snippet.id).recordName, snippet.id.uuidString)
        let uploaded = try XCTUnwrap(cloud.snippets(account: account)[snippet.id])
        XCTAssertTrue(uploaded.hasSameSyncedContent(as: snippet))
        XCTAssertEqual(cloud.recordCount(account: account), 1)

        var renamed = snippet
        renamed.name = "Renamed"
        _ = try await device.store.update(renamed)
        await device.sync()
        XCTAssertEqual(cloud.recordCount(account: account), 1, "a rename updates the same record; the ID never changes")
        XCTAssertEqual(cloud.snippets(account: account)[snippet.id]?.name, "Renamed")
    }

    func testASecondMacReceivesTheLibraryWithoutEchoesOrDuplicates() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let snippet = try await first.store.create(makeSnippet(name: "Shared", keyword: ";sh"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        let received = try await second.store.allSnippets()
        XCTAssertEqual(received.map(\.id), [snippet.id])
        XCTAssertEqual(second.libraryReloads.count, 1, "the library reloads once, for the one real change")
        XCTAssertEqual(first.libraryReloads.count, 0, "its own change echoing back is not a library change")
        let firstPending = try await first.store.pending(account: account)
        let secondPending = try await second.store.pending(account: account)
        XCTAssertEqual(firstPending, [])
        XCTAssertEqual(secondPending, [])
        XCTAssertEqual(cloud.recordCount(account: account), 1)
    }

    func testCrashAfterTheCloudStoredARecordButBeforeTheAcknowledgementReplaysWithoutDuplication() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let snippet = try await device.store.create(makeSnippet(name: "Once only", keyword: ";once"))
        device.engine.crashAfterNextCloudCommit()
        await device.sync()

        XCTAssertEqual(cloud.recordCount(account: account), 1, "the cloud has the record")
        let queued = try await device.store.pending(account: account)
        XCTAssertEqual(queued.count, 1, "but the app never heard back, so the intent is still queued")

        try await device.relaunch(crash: true)
        await device.sync()

        XCTAssertEqual(cloud.recordCount(account: account), 1, "replay creates no second record")
        let local = try await device.store.allSnippets()
        XCTAssertEqual(local.map(\.id), [snippet.id], "and no conflict copy: the cloud's record is recognized as the same data")
        let left = try await device.store.pending(account: account)
        XCTAssertEqual(left, [])
        let base = try await device.store.syncBase(account: account, id: snippet.id)
        XCTAssertEqual(base?.systemFields, FakeCloud.tagData(1))
    }

    func testCrashAfterTheLocalCommitButBeforeAnythingWasSentSendsOnRelaunch() async throws {
        let device = try makeDevice()
        let snippet = try await device.store.create(makeSnippet(name: "v1", keyword: ";v"))
        await device.enableSync()
        var edited = snippet
        edited.name = "v2"
        _ = try await device.store.update(edited)
        cloud.isOffline = true
        try await device.relaunch(crash: true)

        let queued = try await device.store.pending(account: account)
        XCTAssertEqual(queued.count, 1, "the edit survived the crash in the queue")
        XCTAssertEqual(cloud.snippets(account: account)[snippet.id]?.name, "v1")

        cloud.isOffline = false
        await device.sync()
        XCTAssertEqual(cloud.snippets(account: account)[snippet.id]?.name, "v2")
        XCTAssertEqual(cloud.recordCount(account: account), 1)
        let left = try await device.store.pending(account: account)
        XCTAssertEqual(left, [])
    }

    func testAFailedSendKeepsTheRetryIdentityAndTheNextSendAcknowledgesIt() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let snippet = try await device.store.create(makeSnippet(name: "Retry me", keyword: ";r"))
        device.engine.failSends(with: .networkUnavailable)
        await device.sync()

        let failed = try await device.store.pending(account: account)
        XCTAssertEqual(failed.map(\.attempts), [1])
        let status = await device.controller.status
        XCTAssertEqual(status, .failed(.network))
        XCTAssertEqual(cloud.recordCount(account: account), 0)

        device.engine.failSends(with: nil)
        await device.sync()
        XCTAssertNotNil(cloud.snippets(account: account)[snippet.id])
        let left = try await device.store.pending(account: account)
        XCTAssertEqual(left, [])
        let ok = await device.controller.status
        XCTAssertEqual(ok, .upToDate(lastSyncedAt: clock.now))
    }

    func testEngineStateIsDurableAcrossRelaunchesSoNothingIsFetchedTwice() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        _ = try await first.store.create(makeSnippet(name: "Seen once", keyword: ";s"))
        await first.enableSync()
        await second.enableSync()
        XCTAssertEqual(second.libraryReloads.count, 1)

        try await second.relaunch()
        let restored = try XCTUnwrap(second.engine.startStates.last.flatMap { $0 }, "the saved token is handed back to the engine")
        XCTAssertEqual(String(data: restored, encoding: .utf8), "1")
        XCTAssertEqual(second.libraryReloads.count, 1, "nothing was re-fetched after the relaunch")
    }

    func testAnAnswerAcknowledgesOnlyTheRevisionThatWasActuallySent() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let snippet = try await device.store.create(makeSnippet(name: "v1", keyword: ";v"))
        let session = try XCTUnwrap(device.engine.lastSession)
        let first = await session.nextOutgoing(limit: 10)
        var edited = snippet
        edited.name = "v2"
        _ = try await device.store.update(edited)
        let second = await session.nextOutgoing(limit: 10)
        XCTAssertEqual(second.first?.retryIDs.count, 2)

        // The engine sent the first snapshot only; the second batch was never sent.
        await session.deliver(.sent([SendResult(recordID: snippet.id, outcome: .saved(systemFields: FakeCloud.tagData(1)), sentRevision: 1)]))

        let pending = try await device.store.pending(account: account)
        XCTAssertEqual(pending.count, 1, "the v2 edit is still queued")
        XCTAssertEqual(pending.first?.revision, 2)
        let base = try await device.store.syncBase(account: account, id: snippet.id)
        XCTAssertEqual(base?.snapshot?.name, "v1", "the ancestor is exactly what was sent")
        XCTAssertEqual(first.first?.retryIDs.count, 1)

        // An answer for a snapshot nobody handed out acknowledges nothing.
        await session.deliver(.sent([SendResult(recordID: snippet.id, outcome: .saved(systemFields: nil), sentRevision: 99)]))
        let stillPending = try await device.store.pending(account: account)
        XCTAssertEqual(stillPending.count, 1)
    }

    // MARK: Tombstones

    func testADeletePropagatesOnline() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let snippet = try await first.store.create(makeSnippet(name: "Doomed", keyword: ";d"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        try await first.store.delete(id: snippet.id)
        await settle(first, second)

        XCTAssertEqual(cloud.recordCount(account: account), 0)
        let live = try await second.store.snippet(id: snippet.id)
        XCTAssertNil(live)
        let trash = try await second.store.deletedSnippets()
        XCTAssertEqual(trash.map(\.snippet.id), [snippet.id], "the other Mac keeps it recoverable in the trash")
        let echo = try await second.store.pending(account: account)
        XCTAssertEqual(echo, [], "the delete is not sent back")
    }

    func testADeleteMadeOfflinePropagatesAfterRelaunchAndReconnect() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let snippet = try await first.store.create(makeSnippet(name: "Offline delete", keyword: ";od"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        cloud.isOffline = true
        try await first.store.delete(id: snippet.id)
        await first.sync()
        try await first.relaunch()
        let queued = try await first.store.pending(account: account)
        XCTAssertEqual(queued.map(\.operation), [.delete], "the delete waited durably")
        XCTAssertNotNil(cloud.snippets(account: account)[snippet.id])

        cloud.isOffline = false
        await settle(first, second)
        XCTAssertEqual(cloud.recordCount(account: account), 0)
        let live = try await second.store.snippet(id: snippet.id)
        XCTAssertNil(live)
    }

    func testARemoteDeleteOfARecordWeNeverHadIsHarmless() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let stranger = makeSnippet(name: "Never seen")
        cloud.putExternally(account: account, record: try {
            let record = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(stranger.id))
            try SnippetRecord.fill(record, from: stranger)
            return record
        }())
        cloud.deleteExternally(account: account, id: stranger.id)
        await device.sync()
        let all = try await device.store.allSnippets()
        XCTAssertEqual(all, [])
        let status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
    }
}
