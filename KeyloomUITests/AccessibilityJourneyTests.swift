import XCTest

/// J11: what XCUITest can reach of accessibility: keyboard-only operation, accessibility names, and the on-device
/// assistance menu and sheet. Reduce Transparency, Increase Contrast and VoiceOver cannot be driven from here:
/// NOT VERIFIED.
@MainActor
final class AccessibilityJourneyTests: KeyloomUITestCase {
    private let controlTypes: [XCUIElement.ElementType] = [.button, .textField, .checkBox, .switch, .menuButton, .radioButton, .searchField, .popUpButton, .textView]

    /// Controls whose spoken name is empty, as "type (identifier)". System window chrome is excluded.
    private func unnamedControls(in scope: XCUIElement) -> [String] {
        var unnamed: [String] = []
        for type in controlTypes {
            for element in scope.descendants(matching: type).allElementsBoundByIndex {
                let identifier = element.identifier
                if identifier.hasPrefix("_XCUI:") { continue }
                if element.label.isEmpty && element.title.isEmpty { unnamed.append("\(type.rawValue) (\(identifier.isEmpty ? "no identifier" : identifier)) at \(element.frame)") }
            }
        }
        return unnamed
    }

    /// The deepest element that has keyboard focus, described by what it announces.
    private func focusedDescription() -> String {
        let focused = app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).allElementsBoundByIndex
        guard let element = focused.last else { return "nothing" }
        let name = element.label.isEmpty ? element.title : element.label
        return "\(element.elementType.rawValue):\(name.isEmpty ? element.identifier : name)"
    }

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "J11-accessibility__\(name)-\(appearance.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testJ11AccessibilityKeyboardAndNames() {
        journey("J11-accessibility") {
            try createSnippet(name: "Keyboard check", keyword: "::kb", tags: "a11y", body: "Body text")

            // Keyboard-only: Command-N, then Tab through the editor and record where focus goes.
            app.typeKey("n", modifierFlags: .command)
            try need(nameField, "editor after Command-N")
            nameField.click()
            var order = ["start: \(focusedDescription())"]
            for step in 1...8 {
                app.typeKey(.tab, modifierFlags: [])
                order.append("tab \(step): \(focusedDescription())")
            }
            for step in 1...3 {
                app.typeKey(.tab, modifierFlags: .shift)
                order.append("shift-tab \(step): \(focusedDescription())")
            }
            attachText(order.joined(separator: "\n"), name: "tab-order")
            shot("keyboard-focus-walk")
            let stops = order.joined(separator: "\n")
            expect(stops.contains("Expansion keyword"), "Tab reaches the keyword field after the name")
            expect(stops.contains("Tags"), "Tab reaches the tags field")
            expect(!stops.contains("nothing"), "focus is always on something visible while tabbing")
            // Buttons and toggles join the Tab order only with macOS Full Keyboard Access, a system setting this
            // run does not change; their names and shortcuts are checked below instead.

            nameField.click()
            nameField.typeText("Typed by keyboard")
            app.typeKey("s", modifierFlags: .command)
            expect(wait(saveButton, until: "isEnabled == false"), "Command-S saves the draft")
            expect(row("Typed by keyboard").waitForExistence(timeout: 10), "the keyboard-saved snippet is listed")
            app.typeKey("f", modifierFlags: .command)
            expect(wait(searchField, until: "hasKeyboardFocus == true"), "Command-F moves focus to the search field")
            shot("keyboard-find")

            // Names: every control in the library window, the open popover and each Settings tab has a spoken name.
            row("Keyboard check").click()
            let libraryUnnamed = unnamedControls(in: library)
            attachText(libraryUnnamed.joined(separator: "\n"), name: "unnamed-library")
            expect(libraryUnnamed.isEmpty, "library controls without an accessibility name: \(libraryUnnamed)")
            var settingsUnnamed: [String] = []
            for tab in ["General", "Expansion", "Sync & Backups", "Writing Assistance"] {
                let settings = try openSettings(tab: tab)
                settingsUnnamed += unnamedControls(in: settings).map { "\(tab): \($0)" }
            }
            attachText(settingsUnnamed.joined(separator: "\n"), name: "unnamed-settings")
            expect(settingsUnnamed.isEmpty, "Settings controls without an accessibility name: \(settingsUnnamed)")
            shot("settings-names-checked", of: [settingsWindow])
        }
    }

    func testJ11WritingAssistanceMenuAndSheet() {
        journey("J11-assistance") {
            let original = "teh quick brown fox jumps over the lazy dog"
            try createSnippet(name: "Assist me", body: original)

            // Off (the default): the Rewrite Selection action is absent.
            let menu = library.menuButtons.matching(NSPredicate(format: "identifier == 'editor.assistance.menu' OR title == 'Rewrite Selection' OR label == 'Rewrite Selection'")).firstMatch
            expect(!menu.exists, "the assistance action is absent while writing assistance is off")
            shot("assistance-off")

            // Turn it on in Settings > Writing Assistance.
            let settings = try openSettings(tab: "Writing Assistance")
            let toggle = settings.switches["settings.assistance.toggle"]
            try need(toggle, "assistance switch")
            toggle.click()
            expect(wait(toggle, until: "value == 1"), "assistance turns on")
            closeSettings(settings)

            // Offered but disabled until words are selected.
            row("Assist me").click()
            try need(menu, "Rewrite Selection menu")
            try type("", into: bodyField)
            app.typeKey(.rightArrow, modifierFlags: [])
            expect(!menu.isEnabled, "Rewrite Selection is disabled with no selection")
            shot("assistance-no-selection")

            bodyField.typeKey("a", modifierFlags: .command)
            expect(wait(menu, until: "isEnabled == true"), "Rewrite Selection is enabled once words are selected")
            menu.click()
            try need(app.menuItems["Proofread"], "Proofread item")
            expect(app.menuItems["Shorten"].exists && app.menuItems["Change Tone"].exists, "Shorten and Change Tone are offered")
            shot("assistance-menu")
            app.menuItems["Change Tone"].click()
            shot("assistance-tone-submenu")
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])

            // Proofread: preview sheet, Cancel changes nothing.
            menu.click()
            app.menuItems["Proofread"].click()
            let apply = app.buttons["editor.assistance.apply"]
            try need(apply, "Apply in the suggestion sheet", timeout: 20)
            shot("assistance-preview")
            expect(app.buttons["editor.assistance.cancel"].exists, "Cancel is offered beside Apply")
            app.buttons["editor.assistance.cancel"].click()
            expect(disappears(apply), "Cancel closes the sheet")
            expect((bodyField.value as? String) == original, "Cancel leaves the body untouched")

            // Apply, then undo restores the original in one step.
            bodyField.click()
            bodyField.typeKey("a", modifierFlags: .command)
            menu.click()
            app.menuItems["Shorten"].click()
            try need(apply, "Apply in the suggestion sheet, second time", timeout: 20)
            apply.click()
            expect(disappears(apply), "Apply closes the sheet")
            shot("assistance-applied")
            bodyField.click()
            app.typeKey("z", modifierFlags: .command)
            expect((bodyField.value as? String) == original, "Undo restores the original text (body is now: \(String(describing: bodyField.value)))")
            shot("assistance-undone")

            // Off again: the action disappears.
            let again = try openSettings(tab: "Writing Assistance")
            again.switches["settings.assistance.toggle"].click()
            closeSettings(again)
            expect(disappears(menu), "the assistance action disappears when writing assistance is turned off")
            shot("assistance-off-again")
        }
    }
}
