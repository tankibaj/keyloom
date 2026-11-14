import XCTest
@testable import Keyloom

/// Every way out of a dirty editor: another selection, New, Cancel, window close and quit.
@MainActor
final class DismissalTests: LibraryUITestCase {
    private struct Fixture {
        let model: AppModel
        let library: SnippetLibrary
        let first: Snippet
        let second: Snippet
        let log: Log
    }

    @MainActor final class Log { var closed = 0; var quit = 0 }

    private func fixture() async throws -> Fixture {
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] directory in try await openLibrary(at: directory) })
        await model.open()
        let library = try XCTUnwrap(model.library)
        let first = try await seed(library, "First")
        let second = try await seed(library, "Second")
        await model.libraryModel?.refresh()
        let log = Log()
        model.closeWindowAction = { log.closed += 1 }
        model.quitAction = { log.quit += 1 }
        await model.requestSelection(first.id)
        return Fixture(model: model, library: library, first: first, second: second, log: log)
    }

    private func makeDirty(_ f: Fixture) { f.model.editor?.draft.name = "Edited" }

    // MARK: Selection change

    func testSelectingAnotherSnippetWhileCleanSwitchesTheEditor() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.model.editor?.target, .existing(f.first.id))
        await f.model.requestSelection(f.second.id)
        XCTAssertEqual(f.model.editor?.target, .existing(f.second.id))
        XCTAssertEqual(f.model.libraryModel?.selection, f.second.id)
        XCTAssertNil(f.model.pendingDismissal)
    }

    func testSelectionChangeWhileDirtyAsksFirstAndKeepEditingStays() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.requestSelection(f.second.id)
        XCTAssertEqual(f.model.pendingDismissal, .select(f.second.id))
        XCTAssertEqual(f.model.libraryModel?.selection, f.first.id, "the selection has not moved")
        await f.model.resolvePending(.keepEditing)
        XCTAssertNil(f.model.pendingDismissal)
        XCTAssertEqual(f.model.editor?.draft.name, "Edited")
        XCTAssertEqual(f.model.editor?.target, .existing(f.first.id))
    }

    func testSelectionChangeDiscardDropsTheEditsAndMoves() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.requestSelection(f.second.id)
        await f.model.resolvePending(.discard)
        XCTAssertEqual(f.model.editor?.target, .existing(f.second.id))
        let stored = await f.library.snippet(id: f.first.id)
        XCTAssertEqual(stored?.name, "First")
    }

    func testSelectionChangeSaveStoresTheEditsThenMoves() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.requestSelection(f.second.id)
        await f.model.resolvePending(.save)
        XCTAssertEqual(f.model.editor?.target, .existing(f.second.id))
        let stored = await f.library.snippet(id: f.first.id)
        XCTAssertEqual(stored?.name, "Edited")
    }

    func testSelectionDrivenFromTheListAlsoAsks() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.libraryModel?.duplicate(id: f.first.id)
        guard case .select? = f.model.pendingDismissal else { return XCTFail("duplicate must not skip the guard") }
        XCTAssertEqual(f.model.editor?.draft.name, "Edited")
    }

    func testDeletingTheEditedSnippetDoesNotAskAboutItsEdits() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.libraryModel?.delete(id: f.first.id)
        XCTAssertNil(f.model.pendingDismissal)
        XCTAssertEqual(f.model.editor?.target, .existing(f.second.id))
    }

    // MARK: New

    func testNewSnippetWhileDirtyAsksAndDiscardOpensABlankDraft() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.requestNewSnippet()
        XCTAssertEqual(f.model.pendingDismissal, .newSnippet)
        await f.model.resolvePending(.discard)
        XCTAssertEqual(f.model.editor?.target, .new)
        XCTAssertNil(f.model.libraryModel?.selection)
        XCTAssertFalse(f.model.editor?.isDirty ?? true)
    }

    // MARK: Cancel

    func testCancelWhileDirtyAsksThenDiscardRevertsTheEditor() async throws {
        let f = try await fixture()
        makeDirty(f)
        await f.model.requestCancel()
        XCTAssertEqual(f.model.pendingDismissal, .cancelEdit)
        await f.model.resolvePending(.discard)
        XCTAssertEqual(f.model.editor?.draft.name, "First")
        XCTAssertFalse(f.model.editor?.isDirty ?? true)
    }

    func testCancelOnACleanNewDraftClosesIt() async throws {
        let f = try await fixture()
        await f.model.requestNewSnippet()
        await f.model.requestCancel()
        XCTAssertNil(f.model.editor)
        XCTAssertNil(f.model.pendingDismissal)
    }

    // MARK: Window close and quit

    func testCloseWindowWhileCleanProceedsImmediately() async throws {
        let f = try await fixture()
        XCTAssertTrue(f.model.shouldCloseWindow())
        XCTAssertEqual(f.log.closed, 0, "the window system closes it itself")
    }

    func testCloseWindowWhileDirtyAsksAndEachChoiceDoesItsThing() async throws {
        let f = try await fixture()
        makeDirty(f)
        XCTAssertFalse(f.model.shouldCloseWindow())
        XCTAssertEqual(f.model.pendingDismissal, .closeWindow)
        await f.model.resolvePending(.keepEditing)
        XCTAssertEqual(f.log.closed, 0)

        XCTAssertFalse(f.model.shouldCloseWindow())
        await f.model.resolvePending(.discard)
        XCTAssertEqual(f.log.closed, 1)
        let afterDiscard = await f.library.snippet(id: f.first.id)
        XCTAssertEqual(afterDiscard?.name, "First")

        makeDirty(f)
        XCTAssertFalse(f.model.shouldCloseWindow())
        await f.model.resolvePending(.save)
        XCTAssertEqual(f.log.closed, 2)
        let afterSave = await f.library.snippet(id: f.first.id)
        XCTAssertEqual(afterSave?.name, "Edited")
    }

    func testQuitWhileDirtyAsksAndEachChoiceDoesItsThing() async throws {
        let f = try await fixture()
        XCTAssertTrue(f.model.shouldTerminate())
        makeDirty(f)
        XCTAssertFalse(f.model.shouldTerminate())
        XCTAssertEqual(f.model.pendingDismissal, .quit)
        await f.model.resolvePending(.keepEditing)
        XCTAssertEqual(f.log.quit, 0)
        XCTAssertFalse(f.model.shouldTerminate())
        await f.model.resolvePending(.discard)
        XCTAssertEqual(f.log.quit, 1)
        makeDirty(f)
        XCTAssertFalse(f.model.shouldTerminate())
        await f.model.resolvePending(.save)
        XCTAssertEqual(f.log.quit, 2)
        let stored = await f.library.snippet(id: f.first.id)
        XCTAssertEqual(stored?.name, "Edited")
    }

    func testFailedSaveDuringADismissalKeepsTheEditorOpenAndDoesNotProceed() async throws {
        let f = try await fixture()
        f.model.editor?.draft.name = "  "
        XCTAssertFalse(f.model.shouldTerminate())
        await f.model.resolvePending(.save)
        XCTAssertEqual(f.log.quit, 0)
        XCTAssertNil(f.model.pendingDismissal)
        XCTAssertNotNil(f.model.editor?.errorMessage)
        XCTAssertTrue(f.model.editor?.isDirty ?? false)
    }
}
