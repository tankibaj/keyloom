import CloudKit
import XCTest
@testable import Keyloom

/// Slice E: what the user meets: signed out, restricted, quota, switching accounts with work pending,
/// stale callbacks, and the two-Mac off/edit/relaunch/on journey.
final class SyncInteractionTests: SyncTestCase {
    private let accountA = "icloud:A"
    private let accountB = "icloud:B"

    // MARK: Account states

    func testSignedOutShowsItAndStartsWhenTheUserSignsIn() async throws {
        let device = try makeDevice(account: .noAccount)
        let snippet = try await device.store.create(makeSnippet(name: "Made signed out", keyword: ";so"))
        await device.enableSync()
        var status = await device.controller.status
        XCTAssertEqual(status, .signedOut)
        XCTAssertEqual(device.engine.startCount, 0)
        XCTAssertTrue(SyncPreference(defaults: device.defaults).isEnabled, "the choice is kept while signed out")

        device.engine.account = .available(account: accountA)
        await device.controller.accountMayHaveChanged()

        status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertNotNil(cloud.snippets(account: accountA)[snippet.id], "work done while signed out uploads once signed in")
    }

    func testRestrictedAndTemporarilyUnavailableAreDistinctStatuses() async throws {
        let device = try makeDevice(account: .restricted)
        await device.enableSync()
        var status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.restricted))
        device.engine.account = .temporarilyUnavailable
        await device.controller.accountMayHaveChanged()
        status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.temporarilyUnavailable))
        device.engine.account = .couldNotDetermine
        await device.controller.accountMayHaveChanged()
        status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.temporarilyUnavailable))
    }

    func testABuildWithoutTheICloudEntitlementReportsItAndNeverStartsTheEngine() async throws {
        let device = try makeDevice(account: .buildNotProvisioned)
        let snippet = try await device.store.create(makeSnippet(name: "Local", keyword: ";l"))
        await device.enableSync()
        let status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.buildNotProvisioned))
        XCTAssertEqual(device.engine.startCount, 0)
        let local = try await device.store.snippet(id: snippet.id)
        XCTAssertNotNil(local)
    }

    func testICloudBecomingRestrictedWhileRunningStopsSyncAndKeepsLocalWorkUsable() async throws {
        let device = try makeDevice()
        await device.enableSync()
        device.engine.account = .restricted
        await device.sync()
        let status = await device.controller.status
        XCTAssertEqual(status, .unavailable(.restricted))
        XCTAssertEqual(device.engine.stopCount, 1)

        let local = try await device.store.create(makeSnippet(name: "Still works", keyword: ";sw"))
        let stored = try await device.store.snippet(id: local.id)
        XCTAssertNotNil(stored)
        let queued = try await device.store.pending(account: SnippetStore.localSyncAccount)
        XCTAssertEqual(queued.map(\.recordID), [local.id], "kept for when iCloud is allowed again")
    }

    func testSyncNowStartsSyncAfterTheUserSignsBackInWhenNoSessionIsRunning() async throws {
        let device = try makeDevice()
        await device.enableSync()
        device.engine.account = .noAccount
        await device.sync()
        var status = await device.controller.status
        XCTAssertEqual(status, .signedOut)

        device.engine.account = .available(account: accountA)
        let snippet = try await device.store.create(makeSnippet(name: "While signed out", keyword: ";ws"))
        await device.controller.syncNow()

        status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now), "Sync Now works again without relaunching")
        XCTAssertNotNil(cloud.snippets(account: accountA)[snippet.id])
    }

    func testSigningOutWhileRunningStopsTheSessionButKeepsEverything() async throws {
        let device = try makeDevice()
        let snippet = try await device.store.create(makeSnippet(name: "Stays", keyword: ";stay"))
        await device.enableSync()
        device.engine.account = .noAccount
        await device.sync()

        let status = await device.controller.status
        XCTAssertEqual(status, .signedOut)
        XCTAssertEqual(device.engine.stopCount, 1)
        let local = try await device.store.snippet(id: snippet.id)
        XCTAssertNotNil(local)
        XCTAssertNotNil(cloud.snippets(account: accountA)[snippet.id])
        let journal = await device.store.syncAccount
        XCTAssertEqual(journal, SnippetStore.localSyncAccount)
        XCTAssertTrue(SyncPreference(defaults: device.defaults).isEnabled)
    }

    // MARK: Quota

    func testQuotaExceededIsReportedKeepsTheQueueAndRecoversWhenSpaceIsFreed() async throws {
        let device = try makeDevice()
        cloud.maxRecordsPerAccount = 1
        let first = try await device.store.create(makeSnippet(name: "Fits", keyword: ";1"))
        let second = try await device.store.create(makeSnippet(name: "Does not fit", keyword: ";2"))
        await device.enableSync()

        var status = await device.controller.status
        XCTAssertEqual(status, .quotaExceeded)
        XCTAssertEqual(cloud.recordCount(account: accountA), 1)
        let queued = try await device.store.pending(account: accountA)
        XCTAssertEqual(queued.count, 1, "the refused change is kept, with its retry identity")
        XCTAssertEqual(queued[0].attempts, 1)
        let local = try await device.store.allSnippets()
        XCTAssertEqual(Set(local.map(\.id)), [first.id, second.id], "local data is whole")

        cloud.maxRecordsPerAccount = nil
        await device.sync()
        status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(cloud.recordCount(account: accountA), 2)
        let left = try await device.store.pending(account: accountA)
        XCTAssertEqual(left, [])
    }

    // MARK: Account switching

    func testSwitchingAccountsKeepsPendingWorkPerAccountAndNeverCrossesRecords() async throws {
        let device = try makeDevice()
        let ownedByA = try await device.store.create(makeSnippet(name: "A's snippet", keyword: ";a"))
        await device.enableSync()
        XCTAssertNotNil(cloud.snippets(account: accountA)[ownedByA.id])

        // Work pending for A that cannot be sent yet.
        device.engine.failSends(with: .networkUnavailable)
        var pendingEdit = ownedByA
        pendingEdit.name = "A's snippet, edited"
        _ = try await device.store.update(pendingEdit)
        await device.sync()
        let queuedForA = try await device.store.pending(account: accountA)
        XCTAssertEqual(queuedForA.count, 1)

        // The Mac signs in to a different iCloud account.
        device.engine.failSends(with: nil)
        device.engine.account = .available(account: accountB)
        await device.controller.accountMayHaveChanged()

        var status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(cloud.recordCount(account: accountB), 0, "A's snippets are not uploaded to B")
        XCTAssertEqual(cloud.snippets(account: accountA)[ownedByA.id]?.name, "A's snippet", "A's cloud data is untouched")
        let stillQueuedForA = try await device.store.pending(account: accountA)
        XCTAssertEqual(stillQueuedForA, queuedForA, "A's pending work is kept for A")
        let localAfterSwitch = try await device.store.snippet(id: ownedByA.id)
        XCTAssertEqual(localAfterSwitch?.name, "A's snippet, edited", "nothing was wiped locally")

        // Work under B: a new snippet goes to B only; edits to A's snippet stay local.
        let ownedByB = try await device.store.create(makeSnippet(name: "B's snippet", keyword: ";b"))
        var editUnderB = pendingEdit
        editUnderB.name = "A's snippet, edited under B"
        _ = try await device.store.update(editUnderB)
        await device.sync()
        XCTAssertEqual(Set(cloud.snippets(account: accountB).keys), [ownedByB.id])
        XCTAssertNil(cloud.snippets(account: accountA)[ownedByB.id])

        // Back to A: its snippet's latest local state is sent; B's snippet is not.
        device.engine.account = .available(account: accountA)
        await device.controller.accountMayHaveChanged()
        status = await device.controller.status
        XCTAssertEqual(status, .upToDate(lastSyncedAt: clock.now))
        XCTAssertEqual(cloud.snippets(account: accountA)[ownedByA.id]?.name, "A's snippet, edited under B")
        XCTAssertNil(cloud.snippets(account: accountA)[ownedByB.id], "B's record never reaches A")
        let left = try await device.store.pending(account: accountA)
        XCTAssertEqual(left, [])
        let all = try await device.store.allSnippets()
        XCTAssertEqual(Set(all.map(\.id)), [ownedByA.id, ownedByB.id])
    }

    func testCallbacksOfThePreviousAccountAreIgnoredAfterASwitch() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let previous = try XCTUnwrap(device.engine.lastSession)
        device.engine.account = .available(account: accountB)
        await device.controller.accountMayHaveChanged()
        XCTAssertEqual(device.engine.startCount, 2)

        let intruder = makeSnippet(name: "From the old session", keyword: ";old")
        await previous.deliver(.fetched([.upsert(intruder, systemFields: nil)], unreadable: 0))
        let stored = try await device.store.snippet(id: intruder.id)
        XCTAssertNil(stored)
        let ignored = await device.controller.ignoredCallbackCount
        XCTAssertEqual(ignored, 1)
        let base = try await device.store.syncBase(account: accountA, id: intruder.id)
        XCTAssertNil(base)
    }

    func testEnginePerAccountStateIsKeptWhenSwitchingAndResumed() async throws {
        let device = try makeDevice()
        _ = try await device.store.create(makeSnippet(name: "Moves A's token on", keyword: ";t"))
        await device.enableSync()
        await device.sync()
        let stateA = try await device.store.syncEngineState(account: accountA)
        XCTAssertEqual(stateA.flatMap { String(data: $0, encoding: .utf8) }, "1")
        device.engine.account = .available(account: accountB)
        await device.controller.accountMayHaveChanged()
        device.engine.account = .available(account: accountA)
        await device.controller.accountMayHaveChanged()
        let resumed = try XCTUnwrap(device.engine.startStates.last.flatMap { $0 })
        XCTAssertEqual(resumed, stateA, "A's own state, not B's, comes back")
    }

    // MARK: The two-Mac journey

    func testSyncOffOnOneMacEditBothRelaunchThenTurnOnKeepsBothVersions() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let original = try await first.store.create(makeSnippet(name: "Shared", keyword: ";kw", text: "base"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        await first.controller.setEnabled(false)
        var offlineEdit = original
        offlineEdit.name = "Edited on first while off"
        _ = try await first.store.update(offlineEdit)
        var otherEdit = original
        otherEdit.name = "Edited on second"
        _ = try await second.store.update(otherEdit)
        await second.sync()

        try await first.relaunch()
        let status = await first.controller.status
        XCTAssertEqual(status, .off, "the choice survived the relaunch")
        let stillLocal = try await first.store.snippet(id: original.id)
        XCTAssertEqual(stillLocal?.name, "Edited on first while off", "changes stayed local while off")
        XCTAssertEqual(cloud.snippets(account: accountA)[original.id]?.name, "Edited on second")

        await first.enableSync()
        await settle(first, second)

        let firstNames = try await first.store.allSnippets().map(\.name).sorted()
        let secondNames = try await second.store.allSnippets().map(\.name).sorted()
        XCTAssertEqual(firstNames, secondNames, "both Macs end up identical")
        XCTAssertEqual(firstNames.count, 2)
        XCTAssertTrue(firstNames.contains("Edited on second"))
        XCTAssertTrue(firstNames.contains { $0.hasPrefix("Edited on first while off (conflict copy ") }, "both versions survive: \(firstNames)")
    }

    func testTurningOnAfterEditsOnlyLocallyUploadsThemAndFetchesTheRest() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        await second.enableSync()
        let remoteOnly = try await second.store.create(makeSnippet(name: "Created on second", keyword: ";2"))
        await second.sync()
        let localOnly = try await first.store.create(makeSnippet(name: "Created on first while off", keyword: ";1"))

        await first.enableSync()
        await settle(first, second)

        for device in [first, second] {
            let all = try await device.store.allSnippets()
            XCTAssertEqual(Set(all.map(\.id)), [remoteOnly.id, localOnly.id])
        }
    }
}
