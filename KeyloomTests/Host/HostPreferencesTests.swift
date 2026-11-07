import XCTest
@testable import Keyloom

final class HostPreferencesTests: XCTestCase {
    func testPreferencesSavedBeforeTheSwitchExistedKeepTheirValuesAndDefaultToOn() throws {
        let old = #"{"shortcut":{"keyCode":9,"modifiers":1},"excludedBundleIDs":["com.example.Terminal"]}"#
        let decoded = try JSONDecoder().decode(HostPreferences.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.excludedBundleIDs, ["com.example.Terminal"])
        XCTAssertTrue(decoded.expandsInUninspectableApps)
    }

    func testTheSwitchRoundTrips() throws {
        var preferences = HostPreferences()
        preferences.expandsInUninspectableApps = false
        let decoded = try JSONDecoder().decode(HostPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
    }
}
