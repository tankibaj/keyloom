import XCTest

/// J2 search and filters, J9 delete, undo, recover and duplicate.
@MainActor
final class LibraryJourneyTests: KeyloomUITestCase {
    private func seedThreeSnippets() throws {
        try createSnippet(name: "Welcome email", keyword: "::welcome", tags: "email", body: "Hello and welcome aboard")
        try createSnippet(name: "Meeting notes", keyword: "::notes", tags: "work", body: "Agenda for the quarterly review")
        try createSnippet(name: "Sign-off", keyword: "::bye", tags: "email, work", body: "Best regards")
    }

    private func search(_ query: String) throws {
        try need(searchField, "search field")
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        if query.isEmpty { searchField.typeKey(.delete, modifierFlags: []) } else { searchField.typeText(query) }
    }

    func testJ2Search() {
        journey("J2-search") {
            // Empty library: searching has nothing to find, and says so.
            expect(library.staticTexts["No Snippets Yet"].waitForExistence(timeout: 12), "empty library state")
            shot("empty-library")
            try seedThreeSnippets()
            shot("all-snippets")

            try search("welcome")
            expect(row("Welcome email").waitForExistence(timeout: 10) && !row("Meeting notes").exists, "name search narrows the list")
            shot("search-name")

            try search("::notes")
            expect(row("Meeting notes").waitForExistence(timeout: 10) && !row("Welcome email").exists, "keyword search finds the snippet")
            shot("search-keyword")

            try search("work")
            expect(row("Meeting notes").waitForExistence(timeout: 10) && row("Sign-off").exists && !row("Welcome email").exists, "tag search finds tagged snippets")
            shot("search-tag")

            try search("quarterly")
            expect(row("Meeting notes").waitForExistence(timeout: 10) && !row("Sign-off").exists, "body text search finds the snippet")
            shot("search-body")

            try search("zzzz-nothing")
            let noResults = library.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results' OR value BEGINSWITH 'No Results'")).firstMatch
            try need(noResults, "no-results state")
            shot("no-results")
            // Recover by keyboard: Return activates the default Clear Search button once focus leaves the field.
            let clear = library.buttons["Clear Search"]
            try need(clear, "Clear Search button")
            clear.click()
            expect(row("Welcome email").waitForExistence(timeout: 10) && row("Meeting notes").exists, "Clear Search restores the full list")

            // Command-F focuses the search field from anywhere.
            row("Sign-off").click()
            app.typeKey("f", modifierFlags: .command)
            app.typeText("bye")
            expect(row("Sign-off").exists && !row("Welcome email").waitForExistence(timeout: 2), "Command-F then typing searches")
            shot("search-via-command-f")
            try search("")
            expect(row("Welcome email").waitForExistence(timeout: 10), "an empty search shows everything")

            // Tag filter.
            let work = sidebar("work")
            try need(work, "work tag in the sidebar")
            work.click()
            expect(row("Meeting notes").waitForExistence(timeout: 10) && row("Sign-off").exists && !row("Welcome email").exists, "tag filter lists only that tag")
            shot("tag-filter-work")

            // Recently used and Pinned start empty with a way out.
            sidebar("Recently Used").click()
            let unused = library.staticTexts["Nothing Used Yet"]
            expect(unused.waitForExistence(timeout: 10), "Recently Used explains it is empty")
            shot("recently-used-empty")
            sidebar("Pinned").click()
            expect(library.staticTexts["Nothing Pinned Yet"].waitForExistence(timeout: 10), "Pinned explains it is empty")
            shot("pinned-empty")
            let showAll = library.buttons["Show All Snippets"]
            try need(showAll, "Show All Snippets button")
            showAll.click()
            expect(row("Welcome email").waitForExistence(timeout: 10), "Show All Snippets returns to the full list")

            // Pin one, then Pinned lists it.
            row("Sign-off").rightClick()
            let pin = app.menuItems["Pin"]
            try need(pin, "Pin in the row menu")
            shot("row-context-menu")
            pin.click()
            sidebar("Pinned").click()
            expect(row("Sign-off").waitForExistence(timeout: 10) && !row("Welcome email").exists, "Pinned lists the pinned snippet")
            shot("pinned-list")
            sidebar("All Snippets").click()
            expect(row("Welcome email").waitForExistence(timeout: 10), "All Snippets lists everything again")
        }
    }

    func testJ9DeleteUndoRecoverDuplicate() {
        journey("J9-delete-recover") {
            try createSnippet(name: "Alpha", keyword: "::alpha", body: "first")
            try createSnippet(name: "Beta", keyword: "::beta", body: "second")
            shot("two-snippets")

            // Duplicate.
            row("Alpha").rightClick()
            let duplicate = app.menuItems["Duplicate"]
            try need(duplicate, "Duplicate in the row menu")
            duplicate.click()
            expect(wait(snippetList, until: "cells.count == 3"), "Duplicate adds a third row")
            shot("duplicated")

            // Delete through the row menu; the neighbour takes the selection.
            // (The row menu's "Delete" is ambiguous with Edit > Delete in the accessibility tree: use File > Delete Snippet.)
            row("Beta").click()
            app.menuBars.menuBarItems["File"].click()
            let delete = app.menuBars.menuItems["Delete Snippet"]
            try need(delete, "Delete Snippet in the File menu")
            delete.click()
            expect(disappears(row("Beta")), "Delete removes the row")
            shot("deleted")

            // Undo with Command-Z brings it back.
            library.outlines["Snippets"].click()
            app.typeKey("z", modifierFlags: .command)
            expect(row("Beta").waitForExistence(timeout: 10), "Undo restores the deleted snippet")
            shot("undone")

            // Delete with the Delete key, then recover from Recently Deleted.
            row("Beta").click()
            app.typeKey(.delete, modifierFlags: [])
            expect(disappears(row("Beta")), "the Delete key deletes the selected row")
            sidebar("Recently Deleted").click()
            let restore = library.buttons.matching(NSPredicate(format: "label CONTAINS 'Restore Beta'")).firstMatch
            try need(restore, "Restore Beta button")
            shot("recently-deleted")
            // The row and its Restore button are one combined element for VoiceOver (A11Y-2): click where the visible button is.
            restore.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).click()
            expect(disappears(restore), "Restore removes it from Recently Deleted")
            sidebar("All Snippets").click()
            expect(row("Beta").waitForExistence(timeout: 10), "the restored snippet is back in All Snippets")
            shot("restored")
        }
    }
}
