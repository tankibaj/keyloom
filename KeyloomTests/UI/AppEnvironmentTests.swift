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

    func testTheAppStaysResidentAfterTheLastWindowCloses() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    func isolatedDefaults() throws -> UserDefaults {
        let suite = "keyloom-env-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
}
