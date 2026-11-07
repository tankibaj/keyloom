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

    func testSettingsShareTheEnvironmentDefaultsAndTheSyncSeamStartsLocalOnly() async throws {
        let defaults = try isolatedDefaults()
        let environment = AppEnvironment(model: AppModel(dataDirectory: try makeDirectory()), mode: .uiTest, defaults: defaults)
        await environment.start()
        let settings = try XCTUnwrap(environment.services?.settings)
        XCTAssertEqual(settings.sync.status, .off)
        settings.assistance.assistanceEnabled = true
        XCTAssertTrue(defaults.bool(forKey: WritingAssistancePolicy.assistanceKey))
        settings.sync.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: LocalOnlySyncSettings.key))
        XCTAssertTrue(Set([LocalOnlySyncSettings.key]).isDisjoint(with: WritingAssistancePolicy.localOnlyKeys),
                      "Per-device assistance keys are never part of the sync switch's state")
        settings.appearance.preference = .dark
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.key), "dark")
        settings.appearance.preference = .system
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
