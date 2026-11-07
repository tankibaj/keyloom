import XCTest
@testable import Keyloom

@MainActor
final class InputHostControllerTests: StoreTestCase {
    private var library: SnippetLibrary!
    private var destination: FakeDestination!
    private var environment: FakeInputEnvironment!
    private var workspace: FakeWorkspace!
    private var permissions: FakePermissions!
    private var pasteboard: FakePasteboard!
    private var hotKeys: FakeHotKeys!
    private var tap: FakeTap!
    private var prompter: FakePrompter!
    private var picker: FakePicker!
    private var controller: InputHostController!
    private var preferences: UserDefaultsPreferences!

    private func setUpController(typed: String = ";sig", granted: Bool = true) async throws {
        let url = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        library = try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                           now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        addTeardownBlock { [library] in await library?.close() }
        _ = try await library.create(name: "sig", icon: .emoji("x"), keyword: ";sig", enabled: true, tags: [],
                                     template: try TokenParser.parse("Best{cursor} regards").document)
        destination = FakeDestination(prefix: "Dear ", typed: typed, suffix: " tail")
        environment = FakeInputEnvironment()
        workspace = FakeWorkspace()
        permissions = FakePermissions()
        permissions.status = PermissionStatus(accessibility: granted, inputMonitoring: granted, postEvents: granted)
        pasteboard = FakePasteboard(userClipboard: "user clipboard")
        hotKeys = FakeHotKeys()
        tap = FakeTap()
        prompter = FakePrompter()
        picker = FakePicker()
        let suite = "keyloom-host-tests-\(UUID().uuidString)"
        preferences = UserDefaultsPreferences(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let dependencies = HostDependencies(
            destination: destination, pasteboard: pasteboard, keys: FakePasteKeys(), permissions: permissions,
            environment: environment, workspace: workspace, hotKeys: hotKeys, makeTap: { [unowned self] _ in tap },
            settle: { _ in }, ownBundleID: "app.keyloom.Keyloom", permissionPollInterval: nil)
        controller = InputHostController(library: library, prompter: prompter, picker: picker, preferences: preferences,
                                         dependencies: dependencies)
    }

    private func type(_ text: String) {
        for unit in text.utf16 {
            controller.inputHost.handleKeyDown(origin: .physical) {
                KeyContent(units: [unit], keyCode: 0, hasCommandOrControl: false)
            }
        }
    }

    // MARK: Permissions, pause, exclusions

    func testWithoutPermissionsTheTapStaysOffAndStatusSaysSoThenGrantStartsIt() async throws {
        try await setUpController(granted: false)
        controller.start()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(controller.status.permissions, PermissionStatus(accessibility: false, inputMonitoring: false, postEvents: false))
        XCTAssertFalse(controller.status.isTapRunning)
        controller.requestPermissions()
        XCTAssertEqual(permissions.requestCount, 1)
        permissions.status = PermissionStatus(accessibility: true, inputMonitoring: true, postEvents: true)
        controller.refreshPermissions()
        XCTAssertTrue(tap.isRunning)
        XCTAssertTrue(controller.status.isTapRunning)
    }

    func testRevokedPermissionStopsTheTapAndDropsInputWithoutTouchingTheDestination() async throws {
        try await setUpController()
        controller.start()
        XCTAssertTrue(tap.isRunning)
        permissions.status.accessibility = false
        controller.refreshPermissions()
        XCTAssertFalse(tap.isRunning)
        type(";sig")
        await controller.expansionTask?.value
        XCTAssertNil(controller.status.lastOutcome)
        XCTAssertEqual(destination.text, "Dear ;sig tail")
        XCTAssertEqual(destination.writes, [])
    }

    func testPauseAndExcludedAppsReachTheHostAndSurviveRestart() async throws {
        try await setUpController()
        controller.start()
        controller.setExcludedBundleIDs(["com.example.Terminal"])
        XCTAssertEqual(controller.inputHost.excludedBundleIDs, ["com.example.Terminal", "app.keyloom.Keyloom"], "Keyloom never expands in itself")
        controller.setPaused(true)
        XCTAssertTrue(controller.status.isPaused)
        type(";sig")
        XCTAssertNil(controller.expansionTask)
        controller.setPaused(false)
        XCTAssertEqual(preferences.load().excludedBundleIDs, ["com.example.Terminal"])
    }

    // MARK: Typed expansion

    func testTypedKeywordExpandsThroughTheHostOffTheCallback() async throws {
        try await setUpController()
        controller.start()
        type(";sig")
        XCTAssertEqual(destination.text, "Dear ;sig tail", "the callback only hands the match over")
        XCTAssertTrue(controller.inputHost.isSuspended)
        await controller.expansionTask?.value
        XCTAssertEqual(destination.text, "Dear Best regards tail")
        XCTAssertEqual(controller.status.lastOutcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertFalse(controller.inputHost.isSuspended)
    }

    func testSecureInputAppearingBeforeTheWriteFailsClosedWithoutOfferingCopy() async throws {
        try await setUpController()
        controller.start()
        type(";sig")
        environment.isSecureInputActive = true
        await controller.expansionTask?.value
        XCTAssertEqual(controller.status.lastOutcome, .failedClosed(.secureInput))
        XCTAssertFalse(controller.status.hasCopyOffer)
        XCTAssertEqual(destination.text, "Dear ;sig tail")
    }

    // MARK: Picker

    func testPickerCapturesTheDestinationBeforeAnyUIAndInsertsAfterFocusReturns() async throws {
        try await setUpController(typed: "")
        let before = destination.snapshot()
        picker.onPresent = { [unowned self] in
            XCTAssertEqual(destination.snapshot(), before, "nothing has been touched when the UI opens")
            destination.token = FocusToken(pid: 999, element: 77)
            destination.onActivate = { [unowned self] token in destination.token = token }
        }
        controller.openPicker()
        let captured = try XCTUnwrap(try XCTUnwrap(picker.presented.first))
        let rendered = RenderedSnippet(segments: [StyledSegment(text: "Hi", style: [])], plainText: "Hi", cursorOffset: nil)
        let outcome = await controller.insert(rendered, into: captured, route: .plain, snippetID: nil)
        XCTAssertEqual(outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "Dear Hi tail")
        XCTAssertEqual(controller.status.lastOutcome, outcome)
    }

    func testPickerOpensWithoutADestinationForSecureExcludedOrUnsupportedFields() async throws {
        try await setUpController()
        destination.isSecure = true
        controller.openPicker()
        destination.isSecure = false
        destination.role = "AXWebArea"
        controller.openPicker()
        environment.isSecureInputActive = true
        destination.role = "AXTextArea"
        controller.openPicker()
        XCTAssertEqual(picker.presented.count, 3)
        XCTAssertTrue(picker.presented.allSatisfy { $0 == nil })
    }

    func testFieldChangedWhilePickerWasOpenAbortsAndCopyIsOnlyOnExplicitRequest() async throws {
        try await setUpController(typed: "")
        controller.openPicker()
        let captured = try XCTUnwrap(try XCTUnwrap(picker.presented.first))
        destination.text = "Dear  tail, edited"
        let rendered = RenderedSnippet(segments: [StyledSegment(text: "Hi", style: [])], plainText: "Hi", cursorOffset: nil)
        let outcome = await controller.insert(rendered, into: captured, route: .plain, snippetID: nil)
        XCTAssertEqual(outcome, .aborted(.destinationChanged))
        XCTAssertEqual(destination.text, "Dear  tail, edited")
        XCTAssertTrue(controller.status.hasCopyOffer)
        XCTAssertEqual(pasteboard.writeCount, 0)
        controller.copyOffered()
        XCTAssertEqual(pasteboard.plain, "Hi")
        XCTAssertFalse(controller.status.hasCopyOffer)
        XCTAssertEqual(controller.status.lastOutcome, .copied)
    }

    // MARK: Shortcut

    func testShortcutConflictShowsInStatusAndTheHotKeyOpensThePicker() async throws {
        try await setUpController()
        hotKeys.results[.defaultShortcut] = .conflict
        controller.start()
        XCTAssertEqual(controller.status.shortcut, .conflict(.defaultShortcut))
        let other = ShortcutConfig(keyCode: 46, modifiers: ShortcutConfig.defaultShortcut.modifiers)
        XCTAssertEqual(controller.setShortcut(other), .registered(other))
        XCTAssertEqual(preferences.load().shortcut, other)
        hotKeys.press()
        XCTAssertEqual(picker.presented.count, 1)
    }

    func testStopReleasesTheTapAndTheShortcut() async throws {
        try await setUpController()
        controller.start()
        controller.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertNil(hotKeys.registered)
        XCTAssertEqual(controller.status.shortcut, .unregistered)
    }
}
