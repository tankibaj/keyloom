import XCTest

final class AppIdentityTests: XCTestCase {
    func testAppIdentityMatchesTheReleaseBaseline() {
        XCTAssertEqual(AppIdentity.name, "Keyloom")
        XCTAssertEqual(AppIdentity.minimumMajorOSVersion, 26)
    }

    func testTestsRunOnTheSupportedOSAndArchitecture() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        XCTAssertGreaterThanOrEqual(major, AppIdentity.minimumMajorOSVersion)
        #if !arch(arm64)
        XCTFail("Keyloom targets Apple Silicon only")
        #endif
    }
}
