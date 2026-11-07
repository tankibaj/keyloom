import AppKit
import XCTest
@testable import Keyloom

@MainActor
final class AppEnvironmentTests: LibraryUITestCase {
    func testUITestArgumentSelectsTheInertHost() {
        XCTAssertEqual(LaunchMode.resolve(arguments: ["Keyloom", "--keyloom-ui-test"], isRunningTests: false), .uiTest)
    }

    func testHostingXCTestAlsoNeverStartsTheRealHost() {
        XCTAssertEqual(LaunchMode.resolve(arguments: ["Keyloom"], isRunningTests: true), .uiTest)
    }

    func testOrdinaryLaunchUsesTheRealHost() {
        XCTAssertEqual(LaunchMode.resolve(arguments: ["Keyloom"], isRunningTests: false), .live)
        XCTAssertEqual(LaunchMode.resolve(arguments: ["Keyloom", "--keyloom-data-dir", "/tmp/x"], isRunningTests: false), .live)
    }

    func testStartOpensTheLibraryAndBuildsTheServicesOnce() async throws {
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest,
                                         defaults: try isolatedDefaults())
        XCTAssertNil(environment.services)
        await environment.start()
        let first = try XCTUnwrap(environment.services)
        await environment.start()
        XCTAssertTrue(environment.services?.host === first.host)
        XCTAssertFalse(first.host.status.isTapRunning, "The UI-test host never starts the real event tap")
        XCTAssertFalse(first.host.status.permissions.accessibility)
        XCTAssertEqual(first.host.status.shortcut, .registered(.defaultShortcut))
    }

    func testSettingsShareTheEnvironmentDefaultsAndSyncIsTheRealControllerOffByDefault() async throws {
        let defaults = try isolatedDefaults()
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest, defaults: defaults)
        await environment.start()
        let settings = try XCTUnwrap(environment.services?.settings)
        await settings.sync.refresh()
        XCTAssertEqual(settings.sync.status, .off)
        XCTAssertFalse(settings.sync.isEnabled)
        settings.assistance.assistanceEnabled = true
        XCTAssertTrue(defaults.bool(forKey: WritingAssistancePolicy.assistanceKey))
        await settings.sync.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: SyncPreference.key))
        XCTAssertTrue(Set([SyncPreference.key]).isDisjoint(with: WritingAssistancePolicy.localOnlyKeys),
                      "Per-device assistance keys are never part of the sync switch's state")
        settings.appearance.preference = .dark
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.key), "dark")
        settings.appearance.preference = .system
    }

    func testTurningSyncOnWithoutICloudShowsUnavailableAndLocalUseContinues() async throws {
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest, defaults: try isolatedDefaults())
        await environment.start()
        let services = try XCTUnwrap(environment.services)
        await services.settings.sync.setEnabled(true)
        XCTAssertEqual(services.settings.sync.status, .unavailable(.buildNotProvisioned))
        let library = try XCTUnwrap(environment.model.library)
        _ = try await library.create(name: "Still works", icon: .emoji("x"), keyword: nil, template: try document("Body"))
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 1)
    }

    func testTheRealCloudKitAdapterNeverTouchesCloudKitInABuildWithoutTheEntitlement() async {
        let status = await CKSyncEngineAdapter().accountStatus()
        XCTAssertEqual(status, .buildNotProvisioned)
    }

    func testUITestModeWiresTheFakeModelSoTheEditorOffersTheActionOnceAssistanceIsOn() async throws {
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest, defaults: try isolatedDefaults())
        await environment.start()
        let settings = try XCTUnwrap(environment.services?.settings)
        await environment.model.requestNewSnippet()
        let editor = try XCTUnwrap(environment.model.editor)
        XCTAssertEqual(editor.assistance?.isOffered, false, "Off by default: no action")
        settings.assistance.assistanceEnabled = true
        XCTAssertEqual(editor.assistance?.isOffered, true)
        settings.assistance.assistanceEnabled = false
        XCTAssertEqual(editor.assistance?.isOffered, false)
    }

    func testTheAppStaysResidentAfterTheLastWindowCloses() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    func isolatedDefaults() throws -> UserDefaults {
        let suite = "keyloom-env-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
}
