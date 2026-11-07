import CloudKit
import XCTest
@testable import Keyloom

/// Records a newer Keyloom wrote are skipped, remembered per account, never touched while this build is older,
/// and fetched again once an update can read them.
final class SyncNewerSchemaTests: SyncTestCase {
    private let account = "icloud:A"

    /// A record as a Keyloom with record schema 2 would have stored it.
    @discardableResult
    private func putNewerRecord(_ snippet: Snippet, schema: Int = 2, account: String = "icloud:A") throws -> CKRecord {
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(snippet.id))
        try SnippetRecord.fill(record, from: snippet)
        record["schema"] = schema as CKRecordValue
        cloud.putExternally(account: account, record: record)
        return record
    }

    private func marker(_ device: SyncDevice, account: String = "icloud:A") async throws -> NewerSchemaMarker? {
        try await device.store.newerSchemaMarker(account: account)
    }

    // MARK: Remembered

    func testANewerRecordLeavesADurableMarkerAndACount() async throws {
        let device = try makeDevice()
        let newer = makeSnippet(name: "From the future", keyword: ";fut")
        try putNewerRecord(newer, schema: 3)
        await device.enableSync()

        let stored = try await marker(device)
        XCTAssertEqual(stored, NewerSchemaMarker(version: 3, recordIDs: [newer.id]))
        let count = await device.controller.newerSchemaRecordCount
        let skipped = await device.controller.skippedRemoteRecords
        XCTAssertEqual(count, 1)
        XCTAssertEqual(skipped, 1, "the unreadable counter keeps counting it")
        let local = try await device.store.allSnippets()
        XCTAssertEqual(local, [])

        try await device.relaunch()
        let afterRestart = await device.controller.newerSchemaRecordCount
        XCTAssertEqual(afterRestart, 1, "the marker survives a relaunch")
    }

    func testTheMarkerIsKeptAndNothingIsRefetchedWhileTheAppIsStillOlder() async throws {
        let device = try makeDevice()
        try putNewerRecord(makeSnippet(name: "From the future"))
        await device.enableSync()
        try await device.relaunch()
        try await device.relaunch()

        let stored = try await marker(device)
        XCTAssertEqual(stored?.version, 2)
        XCTAssertEqual(device.engine.startStates.map { $0 == nil }, [true, false, false], "only the very first start is from scratch")
        let local = try await device.store.allSnippets()
        XCTAssertEqual(local, [])
    }

    func testRecordsThatBecomeReadableOrAreDeletedLeaveTheMarker() async throws {
        let device = try makeDevice()
        let first = makeSnippet(name: "First", keyword: ";one")
        let second = makeSnippet(name: "Second", keyword: ";two")
        try putNewerRecord(first)
        try putNewerRecord(second)
        await device.enableSync()
        var count = await device.controller.newerSchemaRecordCount
        XCTAssertEqual(count, 2)

        cloud.deleteExternally(account: account, id: first.id)
        await device.sync()
        count = await device.controller.newerSchemaRecordCount
        XCTAssertEqual(count, 1)

        cloud.deleteExternally(account: account, id: second.id)
        await device.sync()
        let stored = try await marker(device)
        XCTAssertNil(stored, "no skipped record is left, so no marker")
    }

    // MARK: Upgrade

    func testAfterTheAppIsUpdatedTheNextStartFetchesEverythingOnceAndClearsTheMarker() async throws {
        let device = try makeDevice()
        let existing = try await device.store.create(makeSnippet(name: "Already here", keyword: ";old"))
        let newer = makeSnippet(name: "From the future", keyword: ";fut")
        try putNewerRecord(newer)
        await device.enableSync()
        let before = try await device.store.allSnippets()
        XCTAssertEqual(before.map(\.id), [existing.id])

        device.supportedSchema = 2
        try await device.relaunch()

        XCTAssertEqual(device.engine.startStates.map { $0 == nil }, [true, true],
                       "the start after the update drops the saved token, so the zone is fetched from the beginning")
        let stored = try await marker(device)
        XCTAssertNil(stored)
        let count = await device.controller.newerSchemaRecordCount
        XCTAssertEqual(count, 0)
        let local = try await device.store.allSnippets()
        XCTAssertEqual(Set(local.map(\.id)), [existing.id, newer.id], "the skipped snippet arrives; the existing one is not duplicated")
        XCTAssertEqual(local.count, 2)
        XCTAssertEqual(local.map(\.name).sorted(), ["Already here", "From the future"], "no conflict copies for unchanged rows")

        try await device.relaunch()
        XCTAssertEqual(device.engine.startStates.map { $0 == nil }, [true, true, false], "exactly one full re-fetch")
        let again = try await device.store.allSnippets()
        XCTAssertEqual(again.count, 2)
    }

    func testAnUpdateThatStillCannotReadTheRecordsKeepsTheMarker() async throws {
        let device = try makeDevice()
        try putNewerRecord(makeSnippet(name: "Far future"), schema: 3)
        await device.enableSync()

        device.supportedSchema = 2
        try await device.relaunch()

        let stored = try await marker(device)
        XCTAssertEqual(stored?.version, 3)
        XCTAssertEqual(device.engine.startStates.map { $0 == nil }, [true, false])
    }

    // MARK: Accounts

    func testTheMarkerBelongsToOneAccount() async throws {
        let device = try makeDevice()
        let newer = makeSnippet(name: "A only")
        try putNewerRecord(newer)
        await device.enableSync()
        let markerA = try await marker(device)
        XCTAssertNotNil(markerA)

        let markerB = try await marker(device, account: "icloud:B")
        XCTAssertNil(markerB)
        try await device.store.saveSyncEngineState(Data("b-token".utf8), account: "icloud:B")
        try await device.store.updateNewerSchemaMarker(seen: [UUID(): 5], resolved: [], account: "icloud:B")

        try await device.store.restartFetchAfterUpgrade(account: "icloud:B")
        let stillA = try await marker(device)
        XCTAssertEqual(stillA, markerA, "restarting one account's fetch leaves the other's marker alone")
        let stateA = try await device.store.syncEngineState(account: account)
        XCTAssertNotNil(stateA)
        let clearedB = try await marker(device, account: "icloud:B")
        XCTAssertNil(clearedB)
    }

    func testAnotherAccountOnTheSameMacNeitherSeesNorRestartsBecauseOfIt() async throws {
        let device = try makeDevice()
        try putNewerRecord(makeSnippet(name: "A only"))
        await device.enableSync()

        device.engine.account = .available(account: "icloud:B")
        device.supportedSchema = 2
        try await device.relaunch()

        XCTAssertEqual(device.engine.startStates.map { $0 == nil }, [true, true], "B has no state of its own, so it starts fresh")
        let forB = try await marker(device, account: "icloud:B")
        XCTAssertNil(forB)
        let forA = try await marker(device)
        XCTAssertNotNil(forA, "A's marker waits for A to sign in again")
        let local = try await device.store.allSnippets()
        XCTAssertEqual(local, [], "A's record never reaches B's session")
    }

    // MARK: Never overwrite or delete what a newer Keyloom wrote

    func testALocalEditOrDeleteNeverReachesARecordThisBuildCannotRead() async throws {
        let device = try makeDevice()
        let mine = try await device.store.create(makeSnippet(name: "Mine", keyword: ";mine"))
        await device.enableSync()
        var updated = mine
        updated.name = "Renamed by the newer app"
        let newerRecord = try putNewerRecord(updated)
        let newerName = newerRecord["name"] as? String
        await device.sync()

        let current = try await device.store.snippet(id: mine.id)
        var edited = try XCTUnwrap(current)
        edited.name = "Edited on the old app"
        _ = try await device.store.update(edited)
        await device.sync()
        var held = cloud.record(account: account, id: mine.id)
        XCTAssertEqual(held?["name"] as? String, newerName, "the newer record is not overwritten")
        XCTAssertEqual(held?["schema"] as? Int, 2)
        let queued = try await device.store.pending(account: account)
        XCTAssertFalse(queued.isEmpty, "the edit stays queued for after the update")

        try await device.store.delete(id: mine.id)
        await device.sync()
        held = cloud.record(account: account, id: mine.id)
        XCTAssertNotNil(held, "the newer record is not deleted")
        XCTAssertEqual(held?["name"] as? String, newerName)
    }

    func testOtherPushesAreNotBlockedByAHeldRecord() async throws {
        let device = try makeDevice()
        let mine = try await device.store.create(makeSnippet(name: "Mine", keyword: ";mine"))
        await device.enableSync()
        try putNewerRecord(mine)
        await device.sync()
        var heldEdit = mine
        heldEdit.name = "Held edit"
        _ = try await device.store.update(heldEdit)
        let other = try await device.store.create(makeSnippet(name: "Other", keyword: ";other"))
        await device.sync()

        XCTAssertEqual(cloud.snippets(account: account)[other.id]?.name, "Other")
    }

    // MARK: Settings

    @MainActor
    func testSettingsExplainsSnippetsFromANewerKeyloomAndDropsTheNoteAfterTheUpdate() async throws {
        let device = try makeDevice()
        try putNewerRecord(makeSnippet(name: "From the future"))
        let model = SyncSettingsViewModel(controller: device.controller, preference: SyncPreference(defaults: device.defaults))
        await model.setEnabled(true)

        XCTAssertEqual(model.newerSchemaNote?.contains("1 snippet"), true)
        XCTAssertEqual(model.newerSchemaNote?.contains("newer Keyloom"), true)
        XCTAssertEqual(model.skippedRemoteRecords, 1)

        device.supportedSchema = 2
        try await device.relaunch()
        let upgraded = SyncSettingsViewModel(controller: device.controller, preference: SyncPreference(defaults: device.defaults))
        await upgraded.refresh()
        XCTAssertNil(upgraded.newerSchemaNote)
    }
}
