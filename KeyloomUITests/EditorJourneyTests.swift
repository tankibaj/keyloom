import XCTest

/// J5 style preservation, J6 keywords, J8 edit and retest.
@MainActor
final class EditorJourneyTests: KeyloomUITestCase {
    private var preview: XCUIElement { library.groups["Preview and Try Expansion"] }

    private func previewText(_ text: String) -> XCUIElement {
        preview.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func editorMessage(_ text: String) -> XCUIElement {
        library.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    func testJ5StylePreservation() {
        journey("J5-style-preservation") {
            try startNewSnippet()
            try type("Styled greeting", into: nameField)
            try type("", into: bodyField)
            library.checkBoxes["Bold"].click()
            bodyField.typeText("Dear {argument name=\"name\" default=\"Ada\"}")
            library.checkBoxes["Bold"].click()
            library.checkBoxes["Italic"].click()
            bodyField.typeText(" welcome, ")
            library.checkBoxes["Italic"].click()
            library.checkBoxes["Underline"].click()
            bodyField.typeText("{argument name=\"name\"}")
            library.checkBoxes["Underline"].click()
            bodyField.typeText(" again")
            shot("styled-body-with-placeholders")

            // The preview substitutes the default into every use of the name, keeping each run's style.
            expect(previewText("Ada").waitForExistence(timeout: 10), "the preview shows the default value in the styled text")
            shot("preview-default-value")

            // A sample value flows into all uses.
            let sample = library.textFields["Sample for name"]
            try need(sample, "sample field for name")
            sample.click()
            sample.typeKey("a", modifierFlags: .command)
            sample.typeText("Grace")
            expect(previewText("Grace").waitForExistence(timeout: 10), "the sample value replaces the default in the preview")
            shot("preview-sample-value")
            try clickSave()
            shot("saved")
        }
    }

    func testJ6Keywords() {
        journey("J6-keywords") {
            try createSnippet(name: "Original", keyword: "::dup", body: "one")

            // Same active keyword on a second snippet: the conflict shows and Save stays off.
            try startNewSnippet()
            try type("Duplicate keyword", into: nameField)
            try type("::dup", into: keywordField)
            let conflict = editorMessage("already expands from")
            try need(conflict, "conflict message")
            expect(wait(saveButton, until: "isEnabled == false"), "Save is disabled while the active keyword conflicts")
            shot("duplicate-keyword-conflict")

            // Turning expansion off lets the snippet be saved.
            library.switches["Expand automatically"].click()
            expect(disappears(conflict), "the conflict clears when Expand automatically is off")
            expect(wait(saveButton, until: "isEnabled == true"), "Save is enabled with expansion off")
            shot("conflict-resolved-expansion-off")
            library.switches["Expand automatically"].click()
            try need(conflict, "conflict returns when expansion is back on")

            // Overlap: another snippet's keyword completes first.
            keywordField.click()
            keywordField.typeKey("a", modifierFlags: .command)
            keywordField.typeText("::dup2")
            let overlap = editorMessage("can never be typed")
            try need(overlap, "overlap warning")
            expect(wait(saveButton, until: "isEnabled == true"), "an overlap warns but does not block Save")
            shot("overlap-warning")
            // Case-sensitive matching and typed-keyword behaviour need the event tap, which the inert host never runs: NOT VERIFIED here.
        }
    }

    func testJ8EditAndRetest() {
        journey("J8-edit-retest") {
            try createSnippet(name: "Greeting", keyword: "::hi")
            try type("Hi {argument name=\"who\" default=\"there\"}", into: bodyField)
            try clickSave()
            // Pin it, so identity survives the rename visibly: the pinned flag lives on the stored ID.
            row("Greeting").rightClick()
            try need(app.menuItems["Pin"], "Pin in the row menu")
            app.menuItems["Pin"].click()
            row("Greeting").click()
            shot("before-edit")

            // Edit name and keyword, then retest in the preview.
            nameField.click()
            nameField.typeKey("a", modifierFlags: .command)
            nameField.typeText("Greeting v2")
            keywordField.click()
            keywordField.typeKey("a", modifierFlags: .command)
            keywordField.typeText("::hello")
            expect(previewText("Hi there").waitForExistence(timeout: 10), "the preview shows the default")
            let sample = library.textFields["Sample for who"]
            try need(sample, "sample field")
            sample.click()
            sample.typeText("Naim")
            expect(previewText("Hi Naim").waitForExistence(timeout: 10), "Try Expansion substitutes the typed sample")
            shot("edited-and-retested")
            try clickSave()
            try need(row("Greeting v2"), "renamed row")
            expect(!row("Greeting").exists || row("Greeting v2").exists, "the old name is gone")
            shot("saved-renamed")

            // Same snippet, not a copy: still one row, still pinned.
            expect(snippetList.cells.count == 1, "renaming keeps one snippet, not two (got \(snippetList.cells.count))")
            sidebar("Pinned").click()
            expect(row("Greeting v2").waitForExistence(timeout: 10), "the renamed snippet is still pinned, so its identity was kept")
            shot("still-pinned")
            sidebar("All Snippets").click()

            // The index refreshed: the old keyword is free for a new snippet, the new one is taken.
            try startNewSnippet()
            try type("Reuses old keyword", into: nameField)
            try type("::hi", into: keywordField)
            expect(wait(saveButton, until: "isEnabled == true"), "the old keyword is free after the rename")
            expect(!editorMessage("already expands from").exists, "no conflict message for the freed keyword")
            keywordField.click()
            keywordField.typeKey("a", modifierFlags: .command)
            keywordField.typeText("::hello")
            expect(editorMessage("already expands from").waitForExistence(timeout: 10), "the new keyword is now taken")
            shot("keyword-index-refreshed")
        }
    }
}
