import XCTest

/// J1: create a snippet with every editor feature, then the Cancel and unsaved-changes protections.
@MainActor
final class CreateJourneyTests: KeyloomUITestCase {
    private func iconControl(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testJ1Create() {
        journey("J1-create") {
            expect(library.staticTexts["No Snippets Yet"].waitForExistence(timeout: 12), "empty library explains itself")
            shot("empty-library")

            try startNewSnippet()
            try type("Meeting follow-up", into: nameField)
            try type("::follow", into: keywordField)
            try type("work, email", into: tagsField)
            nameField.click()
            expect(library.buttons["Remove tag work"].waitForExistence(timeout: 4) && library.buttons["Remove tag email"].exists,
                   "leaving the tags field turns the comma-separated input into removable chips")
            library.buttons["Remove tag email"].click()
            expect(disappears(library.buttons["Remove tag email"]), "the chip's remove button removes the tag")

            // Icon picker (Shortcuts style): Symbols tab with color row, search and grid; then the Emoji tab.
            let icon = library.buttons.matching(NSPredicate(format: "label == 'Icon'")).firstMatch
            try need(icon, "Icon button")
            icon.click()
            let mode = iconControl("icon.mode")
            try need(mode, "icon type control")
            let symbolsTab = mode.radioButtons["Symbols"].exists ? mode.radioButtons["Symbols"] : mode.buttons["Symbols"]
            if symbolsTab.exists { symbolsTab.click() }
            try need(iconControl("icon.search"), "Search Symbols field")
            expect(iconControl("icon.color.red").exists && iconControl("icon.color.blue").exists, "the color row is offered")
            shot("icon-picker-symbols")
            try need(iconControl("icon.color.blue"), "blue color")
            iconControl("icon.color.blue").click()
            try need(iconControl("icon.symbol.envelope"), "envelope symbol")
            iconControl("icon.symbol.envelope").click()
            shot("icon-symbol-blue-envelope-chosen")
            // Search "mail".
            let search = iconControl("icon.search")
            search.click()
            search.typeText("mail")
            expect(iconControl("icon.symbol.envelope").waitForExistence(timeout: 4), "searching “mail” finds the envelope symbol")
            expect(disappears(iconControl("icon.symbol.text.bubble")), "searching “mail” filters unrelated symbols out")
            shot("icon-search-mail")
            // Emoji tab.
            let emojiTab = mode.radioButtons["Emoji"].exists ? mode.radioButtons["Emoji"] : mode.buttons["Emoji"]
            if emojiTab.exists { emojiTab.click() }
            let emoji = iconControl("icon.emoji.✉️")
            try need(emoji, "emoji choice")
            shot("icon-picker-emoji")
            emoji.click()
            app.typeKey(.escape, modifierFlags: [])
            expect(disappears(app.popovers.firstMatch), "Escape closes the icon picker")
            expect((icon.value as? String) == "✉️", "the icon button speaks the chosen emoji (got \(String(describing: icon.value)))")

            // Formatted body: bold, italic, underline, a bulleted and a numbered list.
            try type("", into: bodyField)
            library.checkBoxes["Bold"].click()
            bodyField.typeText("Hi team, ")
            library.checkBoxes["Bold"].click()
            library.checkBoxes["Italic"].click()
            bodyField.typeText("thanks for the sync. ")
            library.checkBoxes["Italic"].click()
            library.checkBoxes["Underline"].click()
            bodyField.typeText("Action items")
            library.checkBoxes["Underline"].click()
            bodyField.typeText(":\n")
            library.checkBoxes["Bulleted List"].click()
            bodyField.typeText("Send the notes\nBook the room\n\n")
            library.checkBoxes["Numbered List"].click()
            bodyField.typeText("Draft the plan\nReview it")
            shot("formatted-body")

            // Insert Placeholder: a date, then an argument through its sheet.
            let placeholders = library.menuButtons["Insert Placeholder"]
            try need(placeholders, "Insert Placeholder menu")
            placeholders.click()
            try need(app.menuItems["Date"], "Date placeholder")
            shot("placeholder-menu")
            app.menuItems["Date"].click()
            placeholders.click()
            try need(app.menuItems["Argument…"], "Argument… item")
            app.menuItems["Argument…"].click()
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

            try clickSave()
            try need(row("Meeting follow-up"), "saved row")
            shot("saved")

            // Escape (close the editor): a clean new draft closes at once; a dirty one asks first.
            try startNewSnippet()
            app.typeKey(.escape, modifierFlags: [])
            expect(disappears(nameField), "Escape on an untouched new snippet closes the editor")
            try startNewSnippet()
            try type("Scratch note", into: nameField)
            let caption = library.staticTexts["Edited · not saved"]
            expect(caption.waitForExistence(timeout: 4), "an edited draft says so in the toolbar")
            library.buttons["Revert"].click()
            expect(disappears(caption), "Revert resets the draft and clears the caption")
            expect((nameField.value as? String ?? "").isEmpty, "Revert empties the new draft's name")
            try type("Scratch note", into: nameField)
            app.typeKey(.escape, modifierFlags: [])
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after Escape")
            shot("cancel-dirty-prompt")
            try resolveDirtySheet("Keep Editing")
            app.typeKey(.escape, modifierFlags: [])
            try resolveDirtySheet("Discard Changes")
            expect(disappears(nameField), "Discard Changes closes the editor")

            // Dirty edit, then select away / close the window / quit.
            try createSnippet(name: "Second snippet")
            row("Meeting follow-up").click()
            try type(" edited", into: nameField)
            row("Second snippet").click()
            try need(library.sheets.buttons["Keep Editing"], "unsaved-changes sheet after selecting away")
            shot("prompt-select-away")
            try resolveDirtySheet("Keep Editing")

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
            expect(app.wait(for: .notRunning, timeout: 10), "Discard Changes lets Quit finish (app state \(app.state.rawValue))")
        }
    }
}
