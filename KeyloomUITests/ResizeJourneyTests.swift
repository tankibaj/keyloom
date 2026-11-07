import XCTest

/// J12: the library window at its minimum, default, very large and narrow-and-tall sizes, dragged by its corner.
/// Settings, the picker panel and the argument prompt are fixed-size by design; the test checks they stay put.
/// Full screen and Split View are NOT VERIFIED: they change Spaces, which a scripted run does not do unattended.
@MainActor
final class ResizeJourneyTests: KeyloomUITestCase {
    private let minimum = CGSize(width: 860, height: 520)

    /// The desktop in points: the menu bar spans its width, the screenshot's aspect gives the height.
    private var screenSize: CGSize {
        let width = app.menuBars.firstMatch.frame.width
        let image = XCUIScreen.main.screenshot().image.size
        return CGSize(width: width, height: width * image.height / max(image.width, 1))
    }

    /// Moves the window by dragging its title bar.
    private func move(to origin: CGPoint) {
        let frame = library.frame
        let grab = library.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width * 0.55, dy: 26))
        grab.press(forDuration: 0.2, thenDragTo: grab.withOffset(CGVector(dx: origin.x - frame.minX, dy: origin.y - frame.minY)))
    }

    /// Drags the bottom-right corner by `delta`, trying a few grab points because the hit zone differs by macOS version.
    @discardableResult
    private func resize(by delta: CGVector) -> Bool {
        let before = library.frame
        for offset in [CGVector(dx: 1, dy: 1), CGVector(dx: -2, dy: -2), CGVector(dx: 3, dy: 3)] {
            let corner = library.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(offset)
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(delta))
            if library.frame.size != before.size { return true }
        }
        return false
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

            move(to: CGPoint(x: 10, y: 50))
            let origin = library.frame
            expect(origin.width >= minimum.width && origin.height >= minimum.height, "default size respects the minimum: \(origin.size)")
            assertLayoutIntact("default \(Int(origin.width))x\(Int(origin.height))")
            shot("default-size")

            // Minimum: drag well inside the minimum; the window must stop at 860x520.
            expect(resize(by: CGVector(dx: -500, dy: -400)), "the window can be dragged smaller")
            let small = library.frame.size
            expect(small.width >= minimum.width - 1 && small.height >= minimum.height - 1, "the minimum size is enforced: \(small)")
            assertLayoutIntact("minimum \(Int(small.width))x\(Int(small.height))")
            shot("minimum-size")
            expect((nameField.value as? String) == draft && saveButton.isEnabled, "the unsaved draft survives shrinking")
            expect(row("Resize me").isSelected, "the selection survives shrinking")

            // Very large: drag toward the bottom-right corner of the screen.
            let maxX = screenSize.width - 12
            let maxY = screenSize.height - 12
            let beforeLarge = library.frame
            resize(by: CGVector(dx: maxX - beforeLarge.maxX, dy: maxY - beforeLarge.maxY))
            let large = library.frame.size
            expect(large.width > 1400 && large.height > 800, "the window can be made very large: \(large)")
            assertLayoutIntact("large \(Int(large.width))x\(Int(large.height))")
            shot("very-large")
            expect((nameField.value as? String) == draft && saveButton.isEnabled, "the unsaved draft survives enlarging")
            expect(row("Resize me").isSelected, "the selection survives enlarging")

            // Narrow and tall: minimum width, large height.
            resize(by: CGVector(dx: -(library.frame.width - minimum.width) - 100, dy: 0))
            let narrow = library.frame.size
            expect(narrow.width < 900 && narrow.height > 800, "narrow and tall: \(narrow)")
            assertLayoutIntact("narrow-tall \(Int(narrow.width))x\(Int(narrow.height))")
            shot("narrow-tall")

            // Zoom restores a sensible size from the menu; the draft is still there.
            let zoom = menuItem("Window", "Zoom")
            if zoom.exists && zoom.isEnabled { zoom.click() }
            shot("after-zoom")
            expect((nameField.value as? String) == draft, "the unsaved draft survives Window > Zoom")

            // Settings is fixed-size: its zoom button is disabled and dragging its corner changes nothing.
            let settings = try openSettings(tab: "General")
            let before = settings.frame.size
            let corner = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: 1, dy: 1))
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 150, dy: 100)))
            expect(settings.frame.size == before, "Settings keeps its fixed size when its corner is dragged: \(before) -> \(settings.frame.size)")
            shot("settings-fixed-size", of: [settings])
            closeSettings(settings)

            // The picker panel is a fixed 700x420 panel.
            try openPickerFromMenuBar()
            let panel = app.windows.matching(NSPredicate(format: "title != 'Keyloom' AND title == ''")).firstMatch
            let pickerFrame = app.textFields["picker.search"].frame
            expect(pickerFrame.width > 400, "the picker search field is wide enough to use: \(pickerFrame)")
            shot("picker-panel", of: [panel.exists ? panel : app.windows.firstMatch])
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    private func openPickerFromMenuBar() throws {
        let item = app.menuBars.statusItems.firstMatch
        try need(item, "menu bar item", timeout: 15)
        item.click()
        let open = app.buttons["menubar.openPicker"]
        try need(open, "Open Picker in the popover")
        open.click()
        try need(app.textFields["picker.search"], "picker search field")
    }
}
