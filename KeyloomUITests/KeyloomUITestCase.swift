import XCTest

/// Launches the Release or Debug app on an empty temporary library with the inert host (`--keyloom-ui-test`):
/// no event tap, no hotkey, no permission prompts, no CloudKit. Drives the app only through the accessibility
/// tree, so what passes here is what VoiceOver and keyboard users can reach.
///
/// These tests need the macOS UI-automation permission for the test runner. Without it, XCUIApplication
/// cannot launch and the run fails at setUp; that is an environment limit, not an app result.
@MainActor
class KeyloomUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("keyloom-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        addTeardownBlock { [dataDirectory] in try? FileManager.default.removeItem(at: dataDirectory!) }
        app = XCUIApplication()
        app.launchArguments = ["--keyloom-ui-test", "--keyloom-data-dir", dataDirectory.path]
        app.launch()
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The library window, waited for rather than assumed.
    var libraryWindow: XCUIElement {
        let window = app.windows["Keyloom"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "library window did not appear")
        return window
    }
}
