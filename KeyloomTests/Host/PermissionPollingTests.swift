import XCTest
@testable import Keyloom

@MainActor
private final class CountingPermissions: PermissionChecking {
    var status = PermissionStatus(accessibility: true)
    private(set) var checks = 0
    func current() -> PermissionStatus {
        checks += 1
        return status
    }
    func request() {}
}

/// The permission check is a synchronous round trip to the TCC daemon on the main thread, so an app that
/// has its permissions must not ask on a timer.
@MainActor
final class PermissionPollingTests: StoreTestCase {
    private var permissions: CountingPermissions!
    private var controller: InputHostController!
    private var tap: FakeTap!
    private var announceChange: (@MainActor () -> Void)?

    private func setUpController(granted: Bool) async throws {
        let url = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        let library = try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                               now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        addTeardownBlock { [library] in await library.close() }
        permissions = CountingPermissions()
        permissions.status = PermissionStatus(accessibility: granted)
        tap = FakeTap()
        let suite = "keyloom-poll-tests-\(UUID().uuidString)"
        let preferences = UserDefaultsPreferences(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        var dependencies = HostDependencies(
            destination: FakeDestination(prefix: "", typed: "", suffix: ""), pasteboard: FakePasteboard(userClipboard: ""),
            keys: FakePasteKeys(), permissions: permissions, environment: FakeInputEnvironment(), workspace: FakeWorkspace(),
            hotKeys: FakeHotKeys(), makeTap: { [unowned self] _ in tap },
            settle: { _ in }, ownBundleID: "com.thenaim.keyloom", permissionPollInterval: 0.02)
        dependencies.observePermissionChanges = { [unowned self] changed in
            announceChange = changed
            return {}
        }
        controller = InputHostController(library: library, prompter: FakePrompter(), picker: FakePicker(), preferences: preferences,
                                         dependencies: dependencies)
    }

    func testGrantedAppIsNotPolled() async throws {
        try await setUpController(granted: true)
        controller.start()
        let checks = permissions.checks
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(permissions.checks, checks)
        XCTAssertTrue(tap.isRunning)
    }

    func testMissingPermissionIsPolledUntilGrantedThenStops() async throws {
        try await setUpController(granted: false)
        controller.start()
        permissions.status = PermissionStatus(accessibility: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(tap.isRunning)
        let checks = permissions.checks
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(permissions.checks, checks)
    }

    func testSystemChangeNotificationRevokesWithoutPolling() async throws {
        try await setUpController(granted: true)
        controller.start()
        permissions.status = PermissionStatus(accessibility: false)
        announceChange?()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(controller.status.permissions, PermissionStatus(accessibility: false))
    }

    func testUnchangedRefreshLeavesStatusUntouched() async throws {
        try await setUpController(granted: true)
        controller.start()
        let before = controller.status
        controller.refreshPermissions()
        XCTAssertEqual(controller.status, before)
    }
}
