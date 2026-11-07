import XCTest
@testable import Keyloom

@MainActor
final class ExpansionSettingsModelTests: LibraryUITestCase {
    private var harness: UIHostHarness!
    private var model: ExpansionSettingsModel!

    override func setUp() async throws {
        let library = try await openTestLibrary()
        harness = makeHarness(library: library, prompter: FakePrompter(), picker: FakePicker())
        harness.controller.start()
        model = ExpansionSettingsModel(host: harness.controller, appName: { $0 == "com.apple.Notes" ? "Notes" : nil })
    }

    func testPauseSwitchReachesTheHostBothWays() {
        model.isPaused = true
        XCTAssertTrue(harness.controller.inputHost.isPaused)
        XCTAssertTrue(model.isPaused)
        model.isPaused = false
        XCTAssertFalse(harness.controller.inputHost.isPaused)
    }

    func testGrantedPermissionsReadAsGranted() {
        XCTAssertTrue(model.permissionRows.allSatisfy(\.isGranted))
        XCTAssertFalse(model.needsPermission)
    }

    func testMissingPermissionsAreListedByNameAndRequestedFromAButton() {
        harness.permissions.status = PermissionStatus(accessibility: false, inputMonitoring: true, postEvents: false)
        model.refresh()
        XCTAssertTrue(model.needsPermission)
        let rows = Dictionary(uniqueKeysWithValues: model.permissionRows.map { ($0.kind, $0) })
        XCTAssertEqual(rows[.accessibility]?.isGranted, false)
        XCTAssertEqual(rows[.inputMonitoring]?.isGranted, true)
        XCTAssertEqual(rows[.pasteEvents]?.isGranted, false)
        XCTAssertEqual(rows[.pasteEvents]?.isRequired, false, "Paste events only back the explicit rich-paste route")
        model.requestPermissions()
        XCTAssertEqual(harness.permissions.requestCount, 1)
    }

    func testAGrantMadeInSystemSettingsAppearsAfterRefresh() {
        harness.permissions.status = PermissionStatus(accessibility: false, inputMonitoring: false, postEvents: false)
        model.refresh()
        XCTAssertTrue(model.needsPermission)
        harness.permissions.status = PermissionStatus(accessibility: true, inputMonitoring: true, postEvents: true)
        model.refresh()
        XCTAssertFalse(model.needsPermission)
    }

    func testEachPermissionLinksToItsSystemSettingsPane() {
        XCTAssertEqual(ExpansionSettingsModel.systemSettingsURL(for: .accessibility).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(ExpansionSettingsModel.systemSettingsURL(for: .inputMonitoring).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func testExcludingAnAppReachesTheHostAndIsListedByName() {
        model.exclude(bundleID: "com.apple.Notes")
        model.exclude(bundleID: "org.example.Unknown")
        XCTAssertEqual(harness.controller.excludedBundleIDs, ["com.apple.Notes", "org.example.Unknown"])
        XCTAssertEqual(model.excludedApps.map(\.name), ["Notes", "org.example.Unknown"], "A name macOS cannot resolve falls back to the bundle ID")
        model.include(bundleID: "com.apple.Notes")
        XCTAssertEqual(harness.controller.excludedBundleIDs, ["org.example.Unknown"])
        XCTAssertEqual(model.excludedApps.map(\.bundleID), ["org.example.Unknown"])
    }

    func testABlankBundleIDIsIgnored() {
        model.exclude(bundleID: "  ")
        XCTAssertTrue(harness.controller.excludedBundleIDs.isEmpty)
    }

    func testAnApplicationBundleIsExcludedByItsBundleID() throws {
        let app = try makeDirectory().appendingPathComponent("Fake.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.Fake</string></dict></plist>"#.utf8)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertTrue(model.exclude(applicationAt: app))
        XCTAssertEqual(harness.controller.excludedBundleIDs, ["com.example.Fake"])
    }

    func testAFolderThatIsNotAnApplicationIsRefused() throws {
        XCTAssertFalse(model.exclude(applicationAt: try makeDirectory()))
        XCTAssertTrue(harness.controller.excludedBundleIDs.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSecureInputIsExplained() {
        XCTAssertNil(model.secureInputNote)
        harness.environment.isSecureInputActive = true
        harness.controller.refreshPermissions()
        XCTAssertNotNil(model.secureInputNote)
    }
}
