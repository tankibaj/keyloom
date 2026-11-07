import CloudKit
import XCTest
@testable import Keyloom

/// Slice C: the per-Mac switch, starting and stopping the engine, fencing and draining callbacks, and the
/// guarantee that the local library never depends on sync.
final class SyncControllerTests: SyncTestCase {
    private let account = "icloud:A"

    private func externalRecord(_ snippet: Snippet) throws -> CKRecord {
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(snippet.id))
        try SnippetRecord.fill(record, from: snippet)
        return record
    }

    // MARK: The switch

    func testSwitchDefaultsToOffAndSurvivesRelaunch() throws {
        let suite = "keyloom.tests.pref.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = SyncPreference(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(first.isEnabled, "sync is off until the user turns it on")
        first.isEnabled = true
        XCTAssertTrue(SyncPreference(defaults: UserDefaults(suiteName: suite)!).isEnabled, "saved across launches")
        first.isEnabled = false
        XCTAssertFalse(SyncPreference(defaults: UserDefaults(suiteName: suite)!).isEnabled)
    }

    func testSwitchIsPerDefaultsDomainSoOneMacNeverTurnsAnotherOn() throws {
        let suite = "keyloom.tests.pref.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        SyncPreference(defaults: UserDefaults(suiteName: suite)!).isEnabled = true
        XCTAssertFalse(SyncPreference(defaults: UserDefaults(suiteName: "keyloom.tests.pref.other.\(UUID().uuidString)")!).isEnabled)
    }

    func testLaunchWithTheSwitchOffNeverTouchesTheCloud() async throws {
        let device = try makeDevice()
        await device.controller.launch()
        let status = await device.controller.status
        XCTAssertEqual(status, .off)
        XCTAssertEqual(device.engine.accountChecks, 0)
        XCTAssertEqual(device.engine.startCount, 0)
    }

    func testEnablingPersistsTheChoiceStartsTheEngineOnceAndUploadsTheExistingLibrary() async throws {
        let device = try makeDevice()
        let existing = try await device.store.create(makeSnippet(name: "Before sync", keyword: ";pre"))

        await device.enableSync()
        await device.enableSync()

        XCTAssertTrue(SyncPreference(defaults: device.defaults).isEnabled)
        XCTAssertEqual(device.engine.startCount, 1, "enabling twice starts one engine")
        let status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(Array(cloud.snippets(account: account).keys), [existing.id])
        let pending = try await device.store.pending(account: account)
        XCTAssertEqual(pending, [])
        let journalAccount = await device.store.syncAccount
        XCTAssertEqual(journalAccount, account, "edits made while syncing are journaled under the account")
    }

    func testRelaunchHonorsTheSavedSwitch() async throws {
        let device = try makeDevice()
        try await device.relaunch()
        XCTAssertEqual(device.engine.startCount, 0, "off stays off")
        await device.enableSync()
        try await device.relaunch()
        XCTAssertEqual(device.engine.startCount, 2, "on starts again at launch")
        let status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
    }

    // MARK: Turning off preserves everything

    func testTurningOffStopsSyncAndNeverWipesTheLibraryOrTheCloud() async throws {
        let device = try makeDevice()
        let kept = try await device.store.create(makeSnippet(name: "Keep me", keyword: ";keep"))
        await device.enableSync()
        let cloudBefore = Set(cloud.snippets(account: account).keys)
        let stateBefore = try await device.store.syncEngineState(account: account)
        XCTAssertNotNil(stateBefore)
        let syncsBefore = device.engine.syncCount

        await device.controller.setEnabled(false)

        let status = await device.controller.status
        XCTAssertEqual(status, .off)
        XCTAssertFalse(SyncPreference(defaults: device.defaults).isEnabled)
        XCTAssertEqual(device.engine.stopCount, 1)
        let local = try await device.store.allSnippets()
        XCTAssertEqual(local.map(\.id), [kept.id], "the local library is untouched")
        XCTAssertEqual(Set(cloud.snippets(account: account).keys), cloudBefore, "existing iCloud records are untouched")
        let stateAfter = try await device.store.syncEngineState(account: account)
        XCTAssertEqual(stateAfter, stateBefore, "engine state is kept for a later resume")

        var edited = kept
        edited.name = "Edited while off"
        _ = try await device.store.update(edited)
        await device.controller.localChangesCommitted()
        await device.controller.syncNow()
        XCTAssertEqual(device.engine.syncCount, syncsBefore, "no cloud traffic while off")
        XCTAssertEqual(cloud.snippets(account: account)[kept.id]?.name, "Keep me")
        let journalAccount = await device.store.syncAccount
        XCTAssertEqual(journalAccount, SnippetStore.localSyncAccount)
        let pending = try await device.store.pending(account: SnippetStore.localSyncAccount)
        XCTAssertEqual(pending.count, 1, "the edit is queued locally for when sync returns")
    }

    func testStoppingTwiceIsSafe() async throws {
        let device = try makeDevice()
        await device.enableSync()
        await device.controller.setEnabled(false)
        await device.controller.setEnabled(false)
        XCTAssertEqual(device.engine.stopCount, 1)
    }

    // MARK: Fencing and draining

    func testCallbacksFromAStoppedSessionAreIgnored() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let late = try XCTUnwrap(device.engine.lastSession)
        await device.controller.setEnabled(false)
        let stateBefore = try await device.store.syncEngineState(account: account)

        let intruder = makeSnippet(name: "Late arrival", keyword: ";late")
        await late.deliver(.fetched([.upsert(intruder, systemFields: nil)], unreadable: 0))
        await late.deliver(.stateUpdated(Data("late-state".utf8)))
        let outgoing = await late.nextOutgoing(limit: 10)

        let stored = try await device.store.snippet(id: intruder.id)
        XCTAssertNil(stored)
        let stateAfter = try await device.store.syncEngineState(account: account)
        XCTAssertEqual(stateAfter, stateBefore)
        XCTAssertEqual(outgoing, [])
        let ignored = await device.controller.ignoredCallbackCount
        XCTAssertEqual(ignored, 3)
    }

    func testStoppingWaitsForACallbackAlreadyInFlight() async throws {
        let device = try makeDevice()
        let gate = Gate()
        device.useController(onLibraryChanged: { await gate.pass() })
        await device.enableSync()
        let arriving = makeSnippet(name: "In flight", keyword: ";fly")
        cloud.putExternally(account: account, record: try externalRecord(arriving))
        let log = EventLog()

        let syncing = Task { await device.sync() }
        while !(await gate.hasEntered) { await Task.yield() }
        let stopping = Task {
            await device.controller.setEnabled(false)
            log.append("stopped")
        }
        while !(await device.controller.isDraining), !log.entries.contains("stopped") { await Task.yield() }
        log.append("released")
        await gate.release()
        await stopping.value
        await syncing.value

        XCTAssertEqual(log.entries, ["released", "stopped"], "stop returns only after the in-flight callback finished")
        let committed = try await device.store.snippet(id: arriving.id)
        XCTAssertNotNil(committed, "the in-flight change committed completely, not half")
        let status = await device.controller.status
        XCTAssertEqual(status, .off)
    }

    func testAStopOvertakenByANewerStartDoesNotResetTheJournalAccountOrStartASecondSession() async throws {
        let device = try makeDevice()
        let gate = Gate()
        device.useController(onLibraryChanged: { await gate.pass() })
        await device.enableSync()
        cloud.putExternally(account: account, record: try externalRecord(makeSnippet(name: "Holds the stop", keyword: ";h")))
        let syncing = Task { await device.sync() }
        while !(await gate.hasEntered) { await Task.yield() }

        // The user switches to account B: the stop of A waits for the callback that is still running.
        device.engine.account = .available(account: "icloud:B")
        let switching = Task { await device.controller.accountMayHaveChanged() }
        while !(await device.controller.isDraining) { await Task.yield() }

        // Meanwhile a newer start for B runs to completion.
        await device.controller.setEnabled(true)
        await gate.release()
        await switching.value
        await syncing.value

        let journal = await device.store.syncAccount
        XCTAssertEqual(journal, "icloud:B", "the late tail of A's stop must not reset the journal account of B's session")
        XCTAssertEqual(device.engine.startCount, 2, "one session for A, one for B, not a third")
        let status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
    }

    // MARK: Local library is unaffected (LocalLibraryUnaffected)

    /// Create, edit, keyword lookup, backup and delete/restore must all work whatever sync is doing.
    private func assertLocalLibraryUnaffected(_ device: SyncDevice, keyword: String = ";lu", file: StaticString = #filePath,
                                              line: UInt = #line) async throws {
        let created = try await device.store.create(makeSnippet(name: "Local work", keyword: keyword, text: "typed"))
        var edited = created
        edited.name = "Local work v2"
        let updated = try await device.store.update(edited)
        XCTAssertEqual(updated.name, "Local work v2", file: file, line: line)

        let indexStore = KeywordIndexStore()
        indexStore.replace(KeywordIndex(snippets: try await device.store.allSnippets()))
        XCTAssertEqual(KeywordMatcher(store: indexStore).feed(keyword)?.snippetID, created.id, "expansion keeps working", file: file, line: line)

        let backup = try await device.store.backup(to: try makeDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "backups keep working", file: file, line: line)

        try await device.store.delete(id: created.id)
        let live = try await device.store.snippet(id: created.id)
        XCTAssertNil(live, file: file, line: line)
        _ = try await device.store.restore(id: created.id)
    }

    func testLocalLibraryUnaffectedWhileSyncIsOff() async throws {
        try await assertLocalLibraryUnaffected(try makeDevice())
    }

    func testLocalLibraryUnaffectedWhileSignedOut() async throws {
        let device = try makeDevice(account: .noAccount)
        await device.enableSync()
        try await assertLocalLibraryUnaffected(device)
    }

    func testLocalLibraryUnaffectedWhenICloudIsRestricted() async throws {
        let device = try makeDevice(account: .restricted)
        await device.enableSync()
        let status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.restricted))
        try await assertLocalLibraryUnaffected(device)
    }

    func testLocalLibraryUnaffectedWhileOfflineAndOverQuota() async throws {
        let device = try makeDevice()
        await device.enableSync()
        _ = try await device.store.create(makeSnippet(name: "Queued", keyword: ";q"))
        cloud.isOffline = true
        await device.sync()
        var status = await device.controller.status
        XCTAssertEqual(status, .failed(.network))
        try await assertLocalLibraryUnaffected(device)

        cloud.isOffline = false
        cloud.maxRecordsPerAccount = 0
        await device.sync()
        status = await device.controller.status
        XCTAssertEqual(status, .quotaExceeded)
        try await assertLocalLibraryUnaffected(device, keyword: ";zz")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var entries: [String] { lock.withLock { items } }
    func append(_ entry: String) { lock.withLock { items.append(entry) } }
}
