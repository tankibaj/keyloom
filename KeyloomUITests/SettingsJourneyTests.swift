import XCTest

/// J10: Settings (Command-comma), every tab, including import preview, export, snapshots and restore.
@MainActor
final class SettingsJourneyTests: KeyloomUITestCase {
    /// Raycast-format sample: one new entry, one whose keyword is taken (::welcome), one with an unsupported placeholder.
    private func writeSampleImport() throws -> URL {
        let sample = """
        [
          {"name": "Imported greeting", "text": "Hello {argument name=\\"who\\"}", "keyword": "::hi"},
          {"name": "Taken keyword", "text": "Welcome again", "keyword": "::welcome"},
          {"name": "Odd placeholder", "text": "Value {mystery thing}", "keyword": "::odd"}
        ]
        """
        let url = dataDirectory.appendingPathComponent("sample-import.json")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testJ10Settings() {
        journey("J10-settings") {
            // The library needs one snippet so a keyword conflict and a snapshot with content exist.
            try createSnippet(name: "Welcome email", keyword: "::welcome", body: "Hello")
            let settings = try openSettings(tab: "General")

            // General: appearance Auto / Light / Dark, then the shortcut recorder.
            let group = settings.radioGroups["settings.general.appearance"]
            expect(group.radioButtons["Auto"].exists && group.radioButtons["Light"].exists && group.radioButtons["Dark"].exists, "Auto, Light and Dark are offered")
            expect(group.radioButtons["Auto"].value as? Int == 1, "Auto is the default appearance")
            shot("general-appearance-control", of: [settings])

            let shortcut = settings.buttons["settings.general.shortcut"]
            try need(shortcut, "shortcut button")
            expect((shortcut.value as? String)?.isEmpty == false, "the shortcut shows its current key combination")
            shortcut.click()
            shot("general-shortcut-recording", of: [settings])
            app.typeKey(.escape, modifierFlags: [])
            expect(settings.buttons["settings.general.shortcutReset"].exists, "Reset is offered")
            expect(settings.switches["settings.general.openAtLogin"].exists && settings.switches["settings.general.showInMenuBar"].exists,
                   "the Startup group offers open at login and show in menu bar")

            // Expansion: permissions (not granted in the inert host), excluded apps.
            try openSettings(tab: "Expansion")
            shot("expansion", of: [settings])
            expect(settings.switches["settings.expansion.uninspectable"].exists, "the behavior switch is offered")
            expect(settings.buttons["settings.expansion.request"].exists, "access can be requested while a permission is missing")

            // Sync & Backups.
            try openSettings(tab: "Sync")
            let sync = settings.switches["settings.sync.toggle"]
            try need(sync, "iCloud sync switch")
            expect((sync.value as? String) == "0" || (sync.value as? Int) == 0, "iCloud Sync is off by default")
            shot("sync-backups-top", of: [settings])
            expect(settings.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'icloud sync is' OR value CONTAINS[c] 'icloud sync is'")).firstMatch.exists,
                   "the sync status line states whether iCloud Sync is on or off")

            // Import: choose the sample file in the open panel, read the preview, then import.
            let sample = try writeSampleImport()
            settings.buttons["settings.import.button"].click()
            try chooseFileInOpenPanel(sample)
            let confirm = settings.sheets.buttons["settings.import.confirm"]
            try need(confirm, "import preview sheet")
            shot("import-preview", of: [settings])
            expect(settings.sheets.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsupported placeholders' OR value CONTAINS 'Unsupported placeholders'")).firstMatch.exists,
                   "the preview warns about the unsupported placeholder")
            confirm.click()
            expect(disappears(confirm), "the preview closes after Import")
            let message = settings.staticTexts["settings.backups.message"]
            try need(message, "import outcome message")
            shot("import-done", of: [settings])

            // Export: the save panel opens (cancelled: the file contents are not the journey).
            settings.buttons["settings.export.native"].click()
            try need(app.sheets.firstMatch, "export save panel")
            shot("export-save-panel", of: [settings, app.sheets.firstMatch])
            app.typeKey(.escape, modifierFlags: [])
            expect(disappears(app.sheets.firstMatch), "Escape cancels the export")

            // Snapshots: back up, then restore with the confirmation.
            settings.buttons["settings.snapshots.backup"].click()
            let restore = settings.buttons["settings.snapshots.restore.0"]
            try need(restore, "a snapshot with a Restore button")
            shot("snapshots", of: [settings])
            restore.click()
            let dialogRestore = settings.sheets.buttons["Restore"]
            try need(dialogRestore, "restore confirmation")
            shot("restore-confirmation", of: [settings])
            settings.sheets.buttons["Cancel"].click()
            expect(disappears(dialogRestore), "Cancel dismisses the restore confirmation")
            restore.click()
            try need(dialogRestore, "restore confirmation, second time")
            dialogRestore.click()
            try need(settings.staticTexts["settings.backups.message"], "restore outcome message")
            shot("restored", of: [settings])

            // Writing Assistance: off by default, then on.
            try openSettings(tab: "Assistance")
            let assistance = settings.switches["settings.assistance.toggle"]
            try need(assistance, "assistance switch")
            expect((assistance.value as? String) == "0" || (assistance.value as? Int) == 0, "writing assistance is off by default")
            shot("writing-assistance-off", of: [settings])
            assistance.click()
            expect(wait(assistance, until: "value == 1"), "writing assistance turns on")
            shot("writing-assistance-on", of: [settings])
        }
    }

    /// Drives the system open panel to `url` with Go to Folder (Command-Shift-G), the way a keyboard user would.
    private func chooseFileInOpenPanel(_ url: URL) throws {
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        try need(panel, "open panel", timeout: 15)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
    }
}
