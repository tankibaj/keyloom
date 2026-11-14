import ServiceManagement
import XCTest
@testable import Keyloom

@MainActor
final class StartupSettingsTests: XCTestCase {
    private final class FakeLoginItem: LoginItem {
        var status: SMAppService.Status = .notRegistered
        var failure: Error?
        private(set) var calls: [String] = []

        func register() throws {
            calls.append("register")
            if let failure { throw failure }
            status = .enabled
        }

        func unregister() throws {
            calls.append("unregister")
            if let failure { throw failure }
            status = .notRegistered
        }
    }

    private struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }

    private func defaults() throws -> UserDefaults {
        let suite = "keyloom-startup-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testTheLoginSwitchReadsTheSystemStatusAndRegistersBothWays() throws {
        let item = FakeLoginItem()
        let settings = StartupSettings(loginItem: item, defaults: try defaults())
        XCTAssertFalse(settings.opensAtLogin)
        settings.opensAtLogin = true
        XCTAssertEqual(item.calls, ["register"])
        XCTAssertTrue(settings.opensAtLogin)
        settings.opensAtLogin = false
        XCTAssertEqual(item.calls, ["register", "unregister"])
        XCTAssertFalse(settings.opensAtLogin)
        XCTAssertNil(settings.errorMessage)
    }

    func testAFailedRegistrationShowsTheErrorAndTheSwitchStaysOff() throws {
        let item = FakeLoginItem()
        item.failure = Refused()
        let settings = StartupSettings(loginItem: item, defaults: try defaults())
        settings.opensAtLogin = true
        XCTAssertFalse(settings.opensAtLogin, "the switch follows the system, not the click")
        XCTAssertEqual(settings.errorMessage, "Couldn’t change the login item: Operation not permitted")
        item.failure = nil
        settings.opensAtLogin = true
        XCTAssertNil(settings.errorMessage, "a later success clears the error")
    }

    func testAChangeMadeInSystemSettingsAppearsAfterRefresh() throws {
        let item = FakeLoginItem()
        let settings = StartupSettings(loginItem: item, defaults: try defaults())
        item.status = .enabled
        XCTAssertFalse(settings.opensAtLogin)
        settings.refresh()
        XCTAssertTrue(settings.opensAtLogin)
    }

    func testAnItemWaitingForApprovalIsOnAndExplained() throws {
        let item = FakeLoginItem()
        item.status = .requiresApproval
        let settings = StartupSettings(loginItem: item, defaults: try defaults())
        XCTAssertTrue(settings.opensAtLogin)
        XCTAssertTrue(settings.needsApproval)
        item.status = .enabled
        settings.refresh()
        XCTAssertFalse(settings.needsApproval)
    }

    func testTheMenuBarItemIsShownByDefaultAndTheChoiceSurvivesARelaunch() throws {
        let store = try defaults()
        let settings = StartupSettings(loginItem: FakeLoginItem(), defaults: store)
        XCTAssertTrue(settings.showInMenuBar)
        XCTAssertNil(store.object(forKey: StartupSettings.showInMenuBarKey), "nothing is written until the user chooses")
        settings.showInMenuBar = false
        XCTAssertEqual(store.object(forKey: "app.keyloom.showInMenuBar") as? Bool, false)
        XCTAssertFalse(StartupSettings(loginItem: FakeLoginItem(), defaults: store).showInMenuBar)
    }
}
