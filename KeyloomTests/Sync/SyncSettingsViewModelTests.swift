import CloudKit
import XCTest
@testable import Keyloom

/// The Settings view model against a real controller, store and preference, and the fake engine.
@MainActor
final class SyncSettingsViewModelTests: SyncTestCase {
    private func makeModel(_ device: SyncDevice) -> SyncSettingsViewModel {
        SyncSettingsViewModel(controller: device.controller, preference: SyncPreference(defaults: device.defaults))
    }

    func testStartsOffWithAnActionableExplanationAndNoSyncNow() async throws {
        let device = try makeDevice()
        let model = makeModel(device)
        await model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.status, .off)
        XCTAssertEqual(model.presentation.text, "iCloud Sync is off")
        XCTAssertFalse(model.presentation.canSyncNow)
        XCTAssertNil(model.pendingNote)
    }

    func testTurningOnAndOffThroughTheModelDrivesTheControllerAndKeepsData() async throws {
        let device = try makeDevice()
        let snippet = try await device.store.create(makeSnippet(name: "Mine", keyword: ";m"))
        let model = makeModel(device)

        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(model.presentation.text, "Up to date")
        XCTAssertTrue(model.presentation.canSyncNow)
        XCTAssertEqual(model.pendingChanges, 0)
        XCTAssertEqual(cloud.recordCount(account: "icloud:A"), 1)

        await model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.status, .off)
        let local = try await device.store.snippet(id: snippet.id)
        XCTAssertNotNil(local)
        XCTAssertEqual(cloud.recordCount(account: "icloud:A"), 1, "iCloud records survive switching off")
    }

    func testEveryStateHasItsOwnTextSymbolAndTheLocalGuarantee() throws {
        var seen: [String: SyncStatus] = [:]
        let states: [SyncStatus] = [.off, .checkingAccount, .signedOut, .unavailable(.restricted), .unavailable(.temporarilyUnavailable),
                                    .unavailable(.buildNotProvisioned), .syncing, .upToDate(lastSyncedAt: clock.now), .quotaExceeded,
                                    .failed(.network), .failed(.recordTooLarge), .failed(.localStorage), .failed(.unexpected(code: 9))]
        for state in states {
            let presentation = SyncStatusPresentation(state)
            XCTAssertFalse(presentation.detail.isEmpty)
            XCTAssertNil(seen[presentation.text], "two states share the text \(presentation.text)")
            seen[presentation.text] = state
            XCTAssertFalse(presentation.symbol.isEmpty, "state is never color alone")
        }
        XCTAssertEqual(seen.count, states.count)
        XCTAssertTrue(SyncStatusPresentation.localLibraryNote.contains("available on this Mac"))
    }

    func testSignedOutAndRestrictedTellTheUserWhatToDoWithoutBlamingIT() async throws {
        let signedOut = try makeDevice(account: .noAccount)
        let signedOutModel = makeModel(signedOut)
        await signedOutModel.setEnabled(true)
        XCTAssertEqual(signedOutModel.status, .signedOut)
        XCTAssertTrue(signedOutModel.presentation.detail.contains("System Settings"))
        XCTAssertFalse(signedOutModel.presentation.canSyncNow)

        let restricted = try makeDevice(account: .restricted)
        let restrictedModel = makeModel(restricted)
        await restrictedModel.setEnabled(true)
        XCTAssertEqual(restrictedModel.status, .unavailable(.restricted))
        XCTAssertFalse(restrictedModel.presentation.canSyncNow)
        XCTAssertFalse(restrictedModel.presentation.detail.lowercased().contains("it department"))
        XCTAssertTrue(restrictedModel.isEnabled, "the choice is kept; it resumes when iCloud is allowed again")
    }

    func testQuotaAndPendingWorkAreShownAndSyncNowRetries() async throws {
        let device = try makeDevice()
        cloud.maxRecordsPerAccount = 0
        _ = try await device.store.create(makeSnippet(name: "Waiting", keyword: ";w"))
        let model = makeModel(device)
        await model.setEnabled(true)
        XCTAssertEqual(model.status, .quotaExceeded)
        XCTAssertEqual(model.presentation.text, "iCloud storage is full")
        XCTAssertEqual(model.pendingChanges, 1)
        XCTAssertNotNil(model.pendingNote)
        XCTAssertTrue(model.presentation.canSyncNow)

        cloud.maxRecordsPerAccount = nil
        await model.syncNow()
        XCTAssertEqual(model.status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(model.pendingChanges, 0)
    }

    func testSkippedRemoteRecordsAreExplained() async throws {
        let device = try makeDevice()
        let model = makeModel(device)
        await model.setEnabled(true)
        XCTAssertNil(model.skippedNote)
        let newer = makeSnippet(name: "Newer")
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(newer.id))
        try SnippetRecord.fill(record, from: newer)
        record["schema"] = 999 as CKRecordValue
        cloud.putExternally(account: "icloud:A", record: record)
        await model.syncNow()
        XCTAssertEqual(model.skippedRemoteRecords, 1)
        XCTAssertEqual(model.skippedNote?.contains("1 iCloud snippets"), true)
    }

    func testObservingFollowsControllerStatusChanges() async throws {
        let device = try makeDevice()
        let model = makeModel(device)
        let watching = Task { await model.observe() }
        await device.controller.setEnabled(true)
        while model.status != .upToDate(lastSyncedAt: clock.now) { await Task.yield() }
        XCTAssertEqual(model.presentation.text, "Up to date")
        watching.cancel()
    }
}
