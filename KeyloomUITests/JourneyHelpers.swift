import XCTest

/// Steps shared by the journeys. Everything goes through the accessibility tree, like a keyboard or VoiceOver user.
@MainActor
extension KeyloomUITestCase {
    var library: XCUIElement { app.windows["Keyloom"] }
    var snippetList: XCUIElement { library.outlines["Snippets"] }
    var nameField: XCUIElement { library.textFields["editor.name"] }
    var keywordField: XCUIElement { library.textFields["Expansion keyword"] }
    var tagsField: XCUIElement { library.textFields["Tags"] }
    var bodyField: XCUIElement { library.textViews["Snippet body"] }
    var saveButton: XCUIElement { library.buttons["editor.save"] }
    var searchField: XCUIElement { library.searchFields.firstMatch }

    /// A list row by the start of its spoken label ("name, keyword ::x, pinned").
    func row(_ name: String) -> XCUIElement {
        snippetList.cells.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func sidebar(_ title: String) -> XCUIElement {
        library.outlines["Library navigation"].staticTexts[title]
    }

    /// Waits until `predicate` holds for `element`, polling through XCTest's expectation machinery.
    func wait(_ element: XCUIElement, until predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func type(_ text: String, into field: XCUIElement) throws {
        try need(field, "field for “\(text)”")
        field.click()
        field.typeText(text)
    }

    /// Opens a blank editor and waits for it.
    func startNewSnippet() throws {
        let button = library.buttons["library.newSnippet"]
        try need(button, "New Snippet button")
        button.click()
        if !nameField.waitForExistence(timeout: 4) { button.click() }
        try need(nameField, "editor name field")
    }

    func clickSave() throws {
        try need(saveButton, "Save button")
        XCTAssertTrue(wait(saveButton, until: "isEnabled == true"), "Save is enabled once the draft is valid")
        saveButton.click()
        XCTAssertTrue(wait(saveButton, until: "isEnabled == false"), "Save disables once the draft is stored")
    }

    /// Creates and saves a snippet with plain body text, leaving it selected in the list.
    func createSnippet(name: String, keyword: String? = nil, tags: String? = nil, body: String? = nil) throws {
        try startNewSnippet()
        try type(name, into: nameField)
        if let keyword { try type(keyword, into: keywordField) }
        if let tags { try type(tags, into: tagsField) }
        if let body { try type(body, into: bodyField) }
        try clickSave()
        try need(row(name), "list row “\(name)”")
    }

    /// Chooses a button of the unsaved-changes sheet: "Save", "Discard Changes" or "Keep Editing".
    func resolveDirtySheet(_ title: String) throws {
        let button = library.sheets.buttons[title]
        try need(button, "“\(title)” in the unsaved-changes sheet")
        button.click()
        XCTAssertTrue(disappears(library.sheets.firstMatch), "the unsaved-changes sheet closes")
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement { app.menuBars.menuBarItems[menu].menus.menuItems[item] }
}
