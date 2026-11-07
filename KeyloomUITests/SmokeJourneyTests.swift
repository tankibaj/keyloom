import XCTest

@MainActor
final class SmokeJourneyTests: KeyloomUITestCase {
    func testEmptyLibraryThenCreateAndSearchASnippet() throws {
        try launchApp()
        let window = libraryWindow
        XCTAssertTrue(window.staticTexts["No Snippets Yet"].waitForExistence(timeout: 10))
        attachScreenshot("empty library")

        window.buttons["library.newSnippet"].click()
        let name = window.textFields["editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Follow up")
        window.buttons["editor.save"].click()
        XCTAssertTrue(window.staticTexts["Follow up"].waitForExistence(timeout: 10), "the saved snippet is listed")

        let search = window.searchFields.firstMatch
        search.click()
        search.typeText("nothing like this")
        XCTAssertTrue(window.staticTexts["No results for “nothing like this”"].waitForExistence(timeout: 10)
                      || window.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No results'")).firstMatch.waitForExistence(timeout: 10))
        attachScreenshot("no search results")
    }

    func testSettingsOpenWithCommandCommaAndEveryTabRenders() throws {
        try launchApp()
        _ = libraryWindow
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title IN {'General','Expansion','Sync','Assistance','Keyloom Settings'}")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Settings window did not open")

        let checks: [(tab: String, element: (XCUIElement) -> XCUIElement)] = [
            ("General", { $0.segmentedControls["settings.general.appearance"] }),
            ("Expansion", { $0.switches["settings.expansion.uninspectable"] }),
            ("Sync", { $0.buttons["settings.snapshots.backup"] }),
            ("Assistance", { $0.switches["Use on-device writing assistance"] }),
        ]
        for check in checks {
            let tab = settings.toolbars.buttons[check.tab]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "\(check.tab) tab missing")
            tab.click()
            XCTAssertTrue(check.element(settings).waitForExistence(timeout: 10), "\(check.tab) content missing")
            attachScreenshot("settings \(check.tab)")
        }
    }

    func testPickerOpensFromTheMenuBarAndCopyWorksWithoutAnInsertTarget() throws {
        try launchApp()
        _ = libraryWindow
        let item = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "menu bar item missing")
        item.click()
        let open = app.buttons["menubar.openPicker"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        let search = app.textFields["picker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "picker did not open")
        attachScreenshot("picker empty library")
        // The inert host has no focused field, so the picker explains that only Copy is offered.
        XCTAssertTrue(app.staticTexts["picker.notice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["picker.insert"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 10), "Escape closes the picker")
    }
}
