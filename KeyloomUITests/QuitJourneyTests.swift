import XCTest

/// Quit with unsaved edits asks first; answering Discard Changes must actually end the process.
@MainActor
final class QuitJourneyTests: KeyloomUITestCase {
    func testQuitExitsAfterDiscardChanges() {
        journey("Quit-discard") {
            try createSnippet(name: "Quit probe")
            row("Quit probe").click()
            try type(" edited", into: nameField)
            app.typeKey("q", modifierFlags: .command)
            try resolveDirtySheet("Discard Changes")
            expect(app.wait(for: .notRunning, timeout: 10), "Quit finishes after Discard Changes (app state \(app.state.rawValue))")
        }
    }
}
