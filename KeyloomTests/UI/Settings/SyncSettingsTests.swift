import XCTest
@testable import Keyloom

@MainActor
final class LocalSyncSettingsTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "keyloom-sync-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testICloudSyncIsOffByDefault() throws {
        let sync = LocalOnlySyncSettings(defaults: try defaults())
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.status, .off)
    }

    func testTheChoiceSurvivesARelaunchAndIsReportedAsNotAvailableYet() throws {
        let store = try defaults()
        LocalOnlySyncSettings(defaults: store).setEnabled(true)
        let relaunched = LocalOnlySyncSettings(defaults: store)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertEqual(relaunched.status, .unavailable)
        relaunched.setEnabled(false)
        XCTAssertEqual(LocalOnlySyncSettings(defaults: store).status, .off)
    }

    func testEveryStatusHasAnExplanationAndASymbol() {
        for status in SyncStatus.allCases {
            XCTAssertFalse(SyncCopy.description(for: status).isEmpty, "\(status)")
            XCTAssertFalse(SyncCopy.symbol(for: status).isEmpty, "\(status)")
        }
    }

    func testSignedOutQuotaAndUnavailableNameTheirCauseWithoutBlamingAnAdministrator() {
        XCTAssertTrue(SyncCopy.description(for: .signedOut).contains("Sign in to iCloud"))
        XCTAssertTrue(SyncCopy.description(for: .quota).contains("storage"))
        for status in SyncStatus.allCases {
            XCTAssertFalse(SyncCopy.description(for: status).lowercased().contains("administrator"), "\(status)")
        }
    }
}
