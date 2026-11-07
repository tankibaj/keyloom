import AppKit
import XCTest
@testable import Keyloom

/// Holds a call open until a test lets it go: a slow iCloud.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Counts what the sync controller asks of CloudKit. No records move.
final class CountingAdapter: SyncEngineAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (syncs: 0, accountChecks: 0)
    private var syncHook: (@Sendable () -> Void)?
    private var accountHook: (@Sendable () -> Void)?
    var gate: AsyncGate?

    var syncCalls: Int { lock.withLock { counts.syncs } }
    var accountChecks: Int { lock.withLock { counts.accountChecks } }
    func onSync(_ hook: @escaping @Sendable () -> Void) { lock.withLock { syncHook = hook } }
    func onAccountCheck(_ hook: @escaping @Sendable () -> Void) { lock.withLock { accountHook = hook } }

    func accountStatus() async -> CloudAccountStatus {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in counts.accountChecks += 1; return accountHook }
        hook?()
        await gate?.wait()
        return .available(account: "icloud:test")
    }

    func start(session: SyncSession, state: Data?) async throws {}
    func stop() async {}

    func syncNow() async throws {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in counts.syncs += 1; return syncHook }
        hook?()
    }
}

@MainActor
final class SyncTriggerTests: LibraryUITestCase {
    private var library: SnippetLibrary!
    private var adapter: CountingAdapter!
    private var controller: SyncController!
    private var triggers: SyncTriggers!
    private var accountChanges: AsyncStream<Void>.Continuation!
    private var center: NotificationCenter!

    override func setUp() async throws {
        library = try await openTestLibrary()
        adapter = CountingAdapter()
        let suite = "keyloom-trigger-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        controller = SyncController(store: library.syncStore, adapter: adapter,
                                    preference: SyncPreference(defaults: UserDefaults(suiteName: suite)!),
                                    onLibraryChanged: { [library] in await library!.reloadAfterSync() })
        await controller.setEnabled(true)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        accountChanges = continuation
        center = NotificationCenter()
        triggers = SyncTriggers(controller: controller, library: library, accountChanges: stream, center: center)
        triggers.start()
        addTeardownBlock { [triggers] in triggers?.stop() }
    }

    func testALocalEditAfterLaunchIsScheduledWithoutWaitingForARelaunch() async throws {
        let baseline = adapter.syncCalls
        let synced = expectation(description: "sync")
        synced.assertForOverFulfill = false
        adapter.onSync { synced.fulfill() }
        try await seed(library, "Edited after launch")
        await fulfillment(of: [synced], timeout: 5)
        XCTAssertGreaterThan(adapter.syncCalls, baseline)
    }

    func testApplyingRemoteChangesDoesNotTriggerAnotherSync() async throws {
        let baseline = adapter.syncCalls
        let synced = expectation(description: "sync")
        synced.assertForOverFulfill = false
        adapter.onSync { synced.fulfill() }
        await library.reloadAfterSync()   // a remote apply, published first
        try await seed(library, "Local edit")   // then a local one, handled in order
        await fulfillment(of: [synced], timeout: 5)
        XCTAssertEqual(adapter.syncCalls - baseline, 1, "only the local edit syncs; the remote apply does not loop")
    }

    func testAnICloudAccountChangeReChecksTheAccount() async throws {
        let baseline = adapter.accountChecks
        let checked = expectation(description: "account check")
        checked.assertForOverFulfill = false
        adapter.onAccountCheck { checked.fulfill() }
        accountChanges.yield()
        await fulfillment(of: [checked], timeout: 5)
        XCTAssertGreaterThan(adapter.accountChecks, baseline)
    }

    func testBecomingActiveReChecksTheAccount() async throws {
        let baseline = adapter.accountChecks
        let checked = expectation(description: "account check")
        checked.assertForOverFulfill = false
        adapter.onAccountCheck { checked.fulfill() }
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [checked], timeout: 5)
        XCTAssertGreaterThan(adapter.accountChecks, baseline)
    }
}

@MainActor
final class SyncLaunchTests: LibraryUITestCase {
    func testStartAssignsServicesWithoutWaitingForASlowICloud() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "keyloom-slow-\(UUID().uuidString)"))
        SyncPreference(defaults: defaults).isEnabled = true
        let adapter = CountingAdapter()
        let gate = AsyncGate()
        adapter.gate = gate
        addTeardownBlock { await gate.open() }
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest, defaults: defaults,
                                         syncAdapter: adapter)
        let started = expectation(description: "start returned")
        Task { await environment.start(); started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertNotNil(environment.services, "the menu bar and Settings must not wait on iCloud")
    }

    func testQuitStopsSyncBeforeTheAppExits() async throws {
        let delegate = AppDelegate()
        var shutdowns = 0
        delegate.shutdown = { shutdowns += 1 }
        let replied = expectation(description: "termination reply")
        var allowed: Bool?
        delegate.replyToTermination = { allowed = $0; replied.fulfill() }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(shutdowns, 1)
        XCTAssertEqual(allowed, true)
    }
}
