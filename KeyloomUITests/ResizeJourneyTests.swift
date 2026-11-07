import XCTest

/// J12: the library window at default, zoomed (very large) and, where the machine allows scripted resizing,
/// minimum and narrow-and-tall sizes.
///
/// XCUITest has no window-size API and its synthesized drags did not move or resize the window on this Mac, so:
/// Window > Zoom gives the large size, and an AppleScript through System Events (needs the runner to be allowed to
/// control System Events) gives exact sizes. If that is denied the sizes it covers are NOT VERIFIED, never faked.
/// Settings, the picker panel and the argument prompt are fixed-size by design; the test checks Settings stays put.
/// Full screen and Split View are NOT VERIFIED: they change Spaces.
@MainActor
final class ResizeJourneyTests: KeyloomUITestCase {
    private let minimum = CGSize(width: 1020, height: 640)

    /// Sets the library window's size and position through System Events; nil on success, else why not.
    private func setWindow(size: CGSize, origin: CGPoint = CGPoint(x: 20, y: 60)) -> String? {
        let source = """
        tell application "System Events" to tell process "Keyloom"
            set position of window "Keyloom" to {\(Int(origin.x)), \(Int(origin.y))}
            set size of window "Keyloom" to {\(Int(size.width)), \(Int(size.height))}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error.map { "\($0[NSAppleScript.errorMessage] ?? $0)" }
    }

    /// Toolbar, search field, list and editor are all present, reachable and inside the window.
    private func assertLayoutIntact(_ size: String) {
        let window = library.frame.insetBy(dx: -1, dy: -1)
        let parts: [(String, XCUIElement)] = [
            ("New Snippet button", library.buttons["library.newSnippet"]), ("search field", searchField), ("snippet list", snippetList),
            ("name field", nameField), ("body", bodyField), ("Save button", saveButton),
        ]
        for (name, element) in parts {
            expect(element.exists && element.isHittable, "\(name) is hittable at \(size)")
            expect(window.contains(element.frame), "\(name) stays inside the window at \(size): \(element.frame) vs \(library.frame)")
        }
    }

    func testJ12WindowResize() {
        journey("J12-window-resize") {
            try createSnippet(name: "Resize me", keyword: "::resize", body: "Body that must survive a resize")
            row("Resize me").click()
            try type(" (unsaved draft)", into: nameField)
            let draft = nameField.value as? String
            expect(draft == "Resize me (unsaved draft)", "an unsaved draft is in the editor (got \(String(describing: draft)))")

            let original = library.frame.size
            assertLayoutIntact("default \(Int(original.width))x\(Int(original.height))")
            shot("default-size")

            // Very large: Window > Zoom.
            let zoom = menuItem("Window", "Zoom")
            app.menuBars.menuBarItems["Window"].click()
            try need(zoom, "Window > Zoom")
            zoom.click()
            expect(waitUntil { self.library.frame.width > original.width + 200 }, "Zoom makes the window much larger (was \(original))")
            let large = library.frame.size
            assertLayoutIntact("zoomed \(Int(large.width))x\(Int(large.height))")
            shot("very-large-zoomed")
            expect((nameField.value as? String) == draft && saveButton.isEnabled, "the unsaved draft survives enlarging")
            expect(row("Resize me").isSelected, "the selection survives enlarging")

            // Exact sizes (minimum, narrow and tall) need System Events; record why if the machine refuses.
            if let refused = setWindow(size: minimum) {
                attachAccessibilityTree("minimum-size-NOT-VERIFIED")
                expect(false, "NOT VERIFIED: minimum and narrow/tall sizes need System Events scripting, which was refused: \(refused)")
            } else {
                let small = library.frame.size
                expect(small.width >= minimum.width - 1 && small.height >= minimum.height - 1, "the window is at least the minimum: \(small)")
                assertLayoutIntact("minimum \(Int(small.width))x\(Int(small.height))")
                shot("minimum-size")
                expect((nameField.value as? String) == draft && saveButton.isEnabled, "the unsaved draft survives shrinking")
                _ = setWindow(size: CGSize(width: 1020, height: 1100), origin: CGPoint(x: 20, y: 40))
                assertLayoutIntact("narrow-tall \(Int(library.frame.width))x\(Int(library.frame.height))")
                shot("narrow-tall")
            }

            // Settings is fixed-size: its zoom button is disabled.
            let settings = try openSettings(tab: "General")
            expect(!settings.buttons["_XCUI:ZoomWindow"].isEnabled, "Settings cannot be zoomed (fixed size by design)")
            shot("settings-fixed-size", of: [settings])
        }
    }
}
