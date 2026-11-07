import XCTest

/// J3 picker and menu-bar popover, J4 template arguments, J7 clipboard fallback.
///
/// The inert host has no focused destination, so Insert can never run here: the picker and popover can only
/// Copy, and the clipboard is in memory (its text is not readable from the test). What needs a real field in
/// another app (typing a keyword, caret placement, a clipboard changed mid-insert) is NOT VERIFIED.
@MainActor
final class InsertJourneyTests: KeyloomUITestCase {
    private var pickerSearch: XCUIElement { app.textFields["picker.search"] }
    private func promptField(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "prompt.field.\(name)").firstMatch
    }

    private func statusItem() throws -> XCUIElement {
        let item = app.menuBars.statusItems.firstMatch
        try need(item, "menu bar item", timeout: 15)
        return item
    }

    private func openPicker() throws {
        try statusItem().click()
        let open = app.buttons["menubar.openPicker"]
        try need(open, "Open Picker in the popover")
        open.click()
        try need(pickerSearch, "picker search field")
    }

    private func pickerRow(_ name: String) -> XCUIElement {
        app.outlines["picker.list"].cells.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func seedPickerSnippets() throws {
        try createSnippet(name: "Welcome email", keyword: "::welcome", tags: "email", body: "Hello and welcome aboard")
        try createSnippet(name: "Meeting notes", keyword: "::notes", tags: "work", body: "Agenda for the quarterly review")
    }

    func testJ3PickerAndMenuBarPopover() {
        journey("J3-picker-popover") {
            // Picker on an empty library.
            try openPicker()
            expect(app.staticTexts["No Snippets Yet"].waitForExistence(timeout: 10), "the picker explains an empty library")
            shot("picker-empty-library")
            app.typeKey(.escape, modifierFlags: [])
            expect(disappears(pickerSearch), "Escape closes the picker")

            try seedPickerSnippets()
            row("Meeting notes").rightClick()
            try need(app.menuItems["Pin"], "Pin in the row menu")
            app.menuItems["Pin"].click()

            try openPicker()
            try need(pickerRow("Welcome email"), "picker row")
            shot("picker-results")

            // Type, then move with the arrows; the preview follows the selection.
            pickerSearch.typeText("e")
            pickerSearch.typeKey(.downArrow, modifierFlags: [])
            let preview = app.descendants(matching: .any)["picker.preview"]
            try need(preview, "preview pane")
            shot("picker-arrow-down")
            pickerSearch.typeKey(.upArrow, modifierFlags: [])
            shot("picker-arrow-up")
            pickerSearch.typeText("zzzz")
            expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results' OR value BEGINSWITH 'No Results'")).firstMatch.waitForExistence(timeout: 10),
                   "the picker says when nothing matches")
            shot("picker-no-results")
            pickerSearch.typeKey("a", modifierFlags: .command)
            pickerSearch.typeKey(.delete, modifierFlags: [])
            try need(pickerRow("Welcome email"), "picker rows return after clearing the search")

            // Insert is unreachable in this mode: no focused destination, so only Copy is offered.
            expect(app.staticTexts["picker.notice"].waitForExistence(timeout: 5), "the picker says why Insert is unavailable")
            expect(!app.buttons["picker.insert"].isEnabled, "Insert is disabled without a destination (inert host)")
            shot("picker-copy-only-notice")

            // Copy with the button; the panel closes.
            let copy = app.buttons["picker.copy"]
            expect(copy.isEnabled, "Copy is available")
            copy.click()
            expect(disappears(pickerSearch), "Copy closes the picker")

            // The menu-bar popover: pinned and recent snippets, actions.
            try statusItem().click()
            try need(app.buttons["menubar.openPicker"], "popover")
            shot("popover", of: [app.dialogs.firstMatch])
            let pinned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'menubar.snippet.'")).firstMatch
            expect(pinned.waitForExistence(timeout: 5), "the pinned snippet is listed in the popover")
            pinned.click()
            let notice = app.staticTexts["menubar.notice"]
            expect(notice.waitForExistence(timeout: 10), "choosing a snippet without a field explains it was copied")
            shot("popover-copied-notice", of: [app.dialogs.firstMatch])
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testJ4TemplateArgumentsPrompt() {
        journey("J4-arguments-prompt") {
            try createSnippet(name: "Reply", keyword: "::reply")
            // Two uses of recipient, one with a default, one with choices; typing the source builds each token.
            try type("Dear {argument name=\"recipient\"}, ", into: bodyField)
            bodyField.typeText("tone: {argument name=\"tone\" default=\"friendly\"} ")
            bodyField.typeText("mood: {argument name=\"mood\" default=\"calm\" options=\"calm, urgent\"} ")
            bodyField.typeText("bye {argument name=\"recipient\"}")
            try clickSave()
            shot("template-in-editor")

            try openPicker()
            try need(pickerRow("Reply"), "Reply in the picker")
            pickerSearch.typeKey(.return, modifierFlags: .command)
            let recipient = promptField("recipient")
            try need(recipient, "recipient field in the prompt")
            shot("prompt-open")
            expect(app.descendants(matching: .any).matching(identifier: "prompt.field.recipient").count == 1, "the repeated recipient name asks one question")
            expect(promptField("tone").exists && promptField("mood").exists, "default and choice arguments get their own fields")
            expect((promptField("tone").value as? String) == "friendly", "the default is prefilled")
            expect(!app.buttons["prompt.confirm"].isEnabled, "Insert waits for the required recipient")
            shot("prompt-required-empty")

            recipient.click()
            recipient.typeText("Ada")
            expect(app.buttons["prompt.confirm"].isEnabled, "Insert is enabled once the recipient is answered")
            shot("prompt-filled")

            // The choice menu.
            let mood = promptField("mood")
            mood.click()
            shot("prompt-choice-menu")
            app.typeKey(.escape, modifierFlags: [])
            expect(mood.exists, "Escape closes the choice menu without closing the prompt")

            // Cancel first: nothing is copied, the prompt closes.
            app.buttons["prompt.cancel"].click()
            expect(disappears(recipient), "Cancel closes the prompt")
            shot("prompt-cancelled")

            // Then Confirm.
            try openPicker()
            try need(pickerRow("Reply"), "Reply in the picker again")
            pickerSearch.typeKey(.return, modifierFlags: .command)
            try need(recipient, "recipient field, second time")
            recipient.click()
            recipient.typeText("Grace")
            app.buttons["prompt.confirm"].click()
            expect(disappears(recipient), "Confirm closes the prompt")
            shot("prompt-confirmed")
        }
    }

    func testJ7ClipboardFallbackCopyPath() {
        journey("J7-clipboard-fallback") {
            try seedPickerSnippets()
            // Copy through the picker: the only route available without a destination.
            try openPicker()
            try need(pickerRow("Welcome email"), "picker row")
            let notice = app.staticTexts["picker.notice"]
            expect(notice.waitForExistence(timeout: 5), "the picker offers Copy and says Insert is unavailable")
            expect(!app.buttons["picker.insert"].isEnabled, "Insert is not offered")
            shot("picker-copy-fallback")
            pickerSearch.typeKey(.return, modifierFlags: [])
            expect(disappears(pickerSearch), "Return copies when Insert is unavailable, and closes the picker")

            // Copy through the popover: pin first so the snippet appears there.
            row("Welcome email").rightClick()
            try need(app.menuItems["Pin"], "Pin in the row menu")
            app.menuItems["Pin"].click()
            try statusItem().click()
            let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'menubar.snippet.'")).firstMatch
            try need(entry, "pinned snippet in the popover")
            entry.click()
            try need(app.staticTexts["menubar.notice"], "copy notice in the popover")
            expect(!app.buttons["menubar.copyRefused"].exists, "no stale refused-copy offer when nothing was refused")
            shot("popover-copy-notice", of: [app.dialogs.firstMatch])
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
