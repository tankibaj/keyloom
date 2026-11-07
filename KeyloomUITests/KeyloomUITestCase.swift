import AppKit
import XCTest

/// Launches the Release or Debug app on an empty temporary library with the inert host (`--keyloom-ui-test`):
/// no event tap, no hotkey, no permission prompts, no CloudKit. Drives the app only through the accessibility
/// tree, so what passes here is what VoiceOver and keyboard users can reach.
///
/// These tests need the macOS UI-automation permission for the test runner. Without it, XCUIApplication
/// cannot launch and the run fails at setUp; that is an environment limit, not an app result.
///
/// Journey tests run their body once per appearance (Light, then Dark) on a freshly launched app, switching the
/// app's own Settings > General appearance (never System Settings). Every screenshot is attached to the test.
@MainActor
class KeyloomUITestCase: XCTestCase {
    enum Appearance: String, CaseIterable {
        case light, dark
        var title: String { rawValue.capitalized }
    }

    struct JourneyFailure: Error, CustomStringConvertible {
        let description: String
    }

    var app: XCUIApplication!
    private(set) var dataDirectory: URL!
    private(set) var appearance = Appearance.light
    private var journeyName = "adhoc"
    private var stepNumber = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: Launch and appearance

    func launchApp(extraArguments: [String] = []) throws {
        app?.terminate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyloom-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        dataDirectory = directory
        app = XCUIApplication()
        app.launchArguments = ["--keyloom-ui-test", "--keyloom-data-dir", directory.path] + extraArguments
        app.launch()
        app.activate()
        // A second Keyloom (a unit-test host, a manual launch) makes XCUITest attach to the wrong process.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.thenaim.keyloom").count
        XCTAssertEqual(instances, 1, "exactly one Keyloom instance is running during the journey")
        if !app.windows["Keyloom"].waitForExistence(timeout: 5) {
            // APP DEFECT D2 (intermittent): the library window is not presented at launch; open it from the menu bar item.
            expect(false, "D2: the library window did not open at launch")
            let item = app.menuBars.statusItems.firstMatch
            if item.waitForExistence(timeout: 5) {
                item.click()
                app.buttons["menubar.openLibrary"].click()
            }
        }
        _ = app.windows["Keyloom"].waitForExistence(timeout: 10)
    }

    /// Runs `body` once on a fresh app and library, in the system's current appearance (the app stays on Auto;
    /// files are named with the mode the screen is actually in). A failure is recorded with a screenshot.
    func journey(_ name: String, _ body: () throws -> Void) {
        journeyName = name
        stepNumber = 0
        appearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        do {
            try launchApp()
            try body()
        } catch {
            XCTFail("\(name) [\(appearance.rawValue)]: \(error)")
            shot("FAILED")
            attachAccessibilityTree()
        }
    }

    /// Opens Settings and selects `tab`: macOS remembers the last tab between launches, so it is always chosen.
    /// Right after launch Settings can show "Starting…" while the services start, or miss the first Command-comma,
    /// so opening is retried (close, reopen) before the journey gives up.
    @discardableResult
    func openSettings(tab: String? = nil) throws -> XCUIElement {
        let target = tab ?? "General"
        for attempt in 1...3 {
            if !settingsWindow.exists {
                app.activate()
                app.typeKey(",", modifierFlags: .command)
                _ = settingsWindow.waitForExistence(timeout: 4)
            }
            let button = settingsWindow.toolbars.buttons[target]
            if button.waitForExistence(timeout: 4) {
                if tab != nil { button.click() }
                return settingsWindow
            }
            attachAccessibilityTree("settings-not-ready-\(attempt)")
            if attempt < 3, settingsWindow.exists { closeSettings(settingsWindow) }
        }
        throw JourneyFailure(description: "Settings window or its \(target) tab not found")
    }

    /// The Settings window: its title is the selected tab's name.
    var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title IN {'General','Expansion','Sync & Backups','Writing Assistance','Keyloom Settings','Settings'}")).firstMatch
    }

    /// Closes through the window's own close button, so the library window can never be the one that closes.
    func closeSettings(_ settings: XCUIElement) {
        settings.buttons["_XCUI:CloseWindow"].click()
        _ = settings.waitForNonExistence(timeout: 5)
    }

    // MARK: Screenshots

    /// One screenshot, attached to the test as `<journey>__<NN>-<step>-<light|dark>`, of the area covered by
    /// `elements` (default: every window, popover and dialog of the app, so a popover hanging out of the window is
    /// not cut off, and nothing else on the desktop is captured beyond the gaps between them). The UI-test runner
    /// is sandboxed and cannot write into the repo, so `scripts/export-ui-screenshots.sh` turns the attachments of
    /// a result bundle into `<root>/<journey>/<NN>-<step>-<light|dark>.png`.
    func shot(_ step: String, of elements: [XCUIElement]? = nil) {
        let targets = elements ?? (app.windows.allElementsBoundByIndex + app.popovers.allElementsBoundByIndex + app.dialogs.allElementsBoundByIndex)
        let region = targets.map(\.frame).filter { $0.width > 0 && $0.height > 0 }.reduce(CGRect.null) { $0.union($1) }
        let screenshot = XCUIScreen.main.screenshot()
        let scale = CGFloat(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width ?? 0) / max(app.menuBars.firstMatch.frame.width, 1)
        guard !region.isNull, scale > 0, let full = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = full.cropping(to: CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
            // No app window to frame: never fall back to the whole desktop, which shows whatever else is open.
            return
        }
        save(png, step: step)
    }

    private func save(_ png: Data, step: String) {
        stepNumber += 1
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(journeyName)__" + String(format: "%02d-%@-%@", stepNumber, step, appearance.rawValue)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The accessibility tree at the point of failure, minus the system menu bar, for diagnosing a missing element.
    func attachAccessibilityTree(_ label: String = "failure") {
        let tree = app.debugDescription.components(separatedBy: "\n").prefix { !$0.contains("MenuBar,") }.joined(separator: "\n")
        let attachment = XCTAttachment(string: tree)
        attachment.name = "\(journeyName)__tree-\(label)-\(appearance.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Kept for ad-hoc attachments that need no file.
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Queries

    /// The library window, waited for rather than assumed.
    var libraryWindow: XCUIElement {
        let window = app.windows["Keyloom"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "library window did not appear")
        return window
    }

    /// Waits for `element`; a missing element ends the journey (nothing after it can be trusted).
    func need(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 4) throws {
        guard element.waitForExistence(timeout: timeout) else { throw JourneyFailure(description: "\(what) not found") }
    }

    /// Soft check: records the failure and keeps the journey going so later steps still produce screenshots.
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        XCTAssertTrue(condition(), message)
    }

    /// True once `element` exists, polled by XCTest rather than slept on.
    func appears(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool { element.waitForExistence(timeout: timeout) }

    func disappears(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool { element.waitForNonExistence(timeout: timeout) }
}
