import XCTest

/// J1: create a snippet with every editor feature, then the Cancel and unsaved-changes protections.
@MainActor
final class CreateJourneyTests: KeyloomUITestCase {
    func testJ1Create() {
        journey("J1-create") {
            expect(library.staticTexts["No Snippets Yet"].waitForExistence(timeout: 10), "empty library explains itself")
            shot("empty-library")

            try startNewSnippet()
            shot("new-editor")

            try type("Meeting follow-up", into: nameField)
            try type("::follow", into: keywordField)
            try type("work, email", into: tagsField)
            shot("name-keyword-tags")

            // Icon: an emoji, then an SF Symbol.
            let icon = library.buttons.matching(NSPredicate(format: "label == 'Icon'")).firstMatch
            try need(icon, "Icon button")
            icon.click()
            let emoji = app.buttons["✉️"]
            try need(emoji, "emoji choice")
            shot("icon-picker", of: nil)
            emoji.click()
            try need(library.buttons.matching(NSPredicate(format: "label == 'Icon' AND value == '✉️'")).firstMatch, "emoji applied")
            expect(disappears(app.popovers.firstMatch), "choosing an icon closes the picker")
            icon.click()
            if !app.buttons["star"].waitForExistence(timeout: 3) {
                // APP DEFECT D1: the first click on Icon after choosing one does not reopen the picker.
                expect(false, "D1: after choosing an icon, one click on the Icon button reopens the picker (it did not)")
                nameField.click()
                icon.click()
            }
            let star = app.buttons["star"]
            try need(star, "symbol choice")
            star.click()
            expect(icon.value as? String == "star", "the icon button speaks the chosen symbol (got \(String(describing: icon.value)))")
            app.typeKey(.escape, modifierFlags: [])
            shot("icon-chosen")

            // Formatted body: bold, italic, underline, a bulleted and a numbered list.
            try type("", into: bodyField)
            let bold = library.checkBoxes["Bold"], italic = library.checkBoxes["Italic"], underline = library.checkBoxes["Underline"]
            bold.click()
            bodyField.typeText("Hi team, ")
            expect(bold.value as? Int == 1, "Bold shows pressed while bold text is typed")
            bold.click()
            italic.click()
            bodyField.typeText("thanks for the sync. ")
            italic.click()
            underline.click()
            bodyField.typeText("Action items")
            underline.click()
            bodyField.typeText(":\n")
            library.checkBoxes["Bulleted List"].click()
            bodyField.typeText("Send the notes\nBook the room\n\n")
            library.checkBoxes["Numbered List"].click()
            bodyField.typeText("Draft the plan\nReview it")
            shot("formatted-body")

            // Insert Placeholder: the menu, a date, then an argument through its sheet.
            let placeholders = library.menuButtons["Insert Placeholder"]
            try need(placeholders, "Insert Placeholder menu")
            placeholders.click()
            let date = app.menuItems["Date"]
            try need(date, "Date placeholder")
            shot("placeholder-menu")
            try need(date, "Date placeholder still offered")
            date.click()
            placeholders.click()
            let argument = app.menuItems["Argument…"]
            try need(argument, "Argument… item")
            argument.click()
            let sheet = library.sheets.firstMatch
            try need(sheet, "argument sheet")
            let sheetFields = sheet.textFields
            expect(sheetFields.count == 3 && sheetFields.allElementsBoundByIndex.allSatisfy { !$0.label.isEmpty },
                   "A11Y-1: the Insert Argument fields (Name, Default value, Choices) have an accessibility label; XCUI sees none")
            try type("recipient", into: sheetFields.element(boundBy: 0))
            try type("team", into: sheetFields.element(boundBy: 1))
            shot("argument-sheet")
            sheet.buttons["Insert"].click()
            expect(disappears(sheet), "the argument sheet closes after Insert")
            shot("placeholders-inserted")

            try clickSave()
            try need(row("Meeting follow-up"), "saved row")
            shot("saved")

            // Cancel: a clean new draft closes at once; a dirty one asks first.
            try startNewSnippet()
            library.buttons["Cancel"].click()
            expect(disappears(nameField), "Cancel on an untouched new snippet closes the editor")
            shot("cancel-clean")
            try startNewSnippet()
            try type("Scratch note", into: nameField)
            library.buttons["Cancel"].click()
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after Cancel")
            shot("cancel-dirty-prompt")
            try resolveDirtySheet("Keep Editing")
            expect((nameField.value as? String) == "Scratch note", "Keep Editing leaves the draft as typed")
            library.buttons["Cancel"].click()
            try resolveDirtySheet("Discard Changes")
            expect(disappears(nameField), "Discard Changes closes the editor")
            shot("cancel-discarded")

            // Dirty edit, then select away / close the window / quit.
            try createSnippet(name: "Second snippet")
            try need(row("Meeting follow-up"), "first snippet")
            row("Meeting follow-up").click()
            try type(" edited", into: nameField)
            row("Second snippet").click()
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after selecting away")
            shot("prompt-select-away")
            try resolveDirtySheet("Keep Editing")
            expect(nameField.exists, "Keep Editing stays on the edited snippet")

            app.typeKey("w", modifierFlags: .command)
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after closing the window")
            shot("prompt-close-window")
            try resolveDirtySheet("Keep Editing")

            app.typeKey("q", modifierFlags: .command)
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after Quit")
            shot("prompt-quit")
            try resolveDirtySheet("Keep Editing")
            expect(app.state == .runningForeground, "Keep Editing keeps the app running")

            app.typeKey("q", modifierFlags: .command)
            try resolveDirtySheet("Discard Changes")
            expect(app.wait(for: .notRunning, timeout: 20), "Discard Changes lets Quit finish (app state \(app.state.rawValue))")
        }
    }
}
