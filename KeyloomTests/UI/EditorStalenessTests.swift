import XCTest
@testable import Keyloom

@MainActor
final class EditorStalenessTests: LibraryUITestCase {
    private func openEditor(_ library: SnippetLibrary, _ snippet: Snippet) -> EditorViewModel {
        EditorViewModel(library: library, snippet: snippet)
    }

    /// What a sync apply does to the stored row, then to the library's snapshot.
    private func remoteEdit(_ library: SnippetLibrary, _ id: UUID, _ change: (inout Snippet) -> Void) async throws {
        let store = library.syncStore
        var stored = try required(try await store.snippet(id: id))
        change(&stored)
        _ = try await store.update(stored)
        await library.reloadAfterSync()
    }

    func testACleanEditorTakesARemoteEdit() async throws {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: "Old body")
        let editor = openEditor(library, snippet)
        try await remoteEdit(library, snippet.id) { $0.template = try! TokenParser.parse("Remote body").document; $0.name = "Remote name" }
        await editor.refreshFromLibrary()
        XCTAssertEqual(editor.draft.name, "Remote name")
        XCTAssertEqual(editor.draft.body.plainText, "Remote body")
        XCTAssertFalse(editor.isDirty)
    }

    func testADirtyEditorKeepsTheUsersDraft() async throws {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: "Old body")
        let editor = openEditor(library, snippet)
        editor.draft.name = "My unsaved name"
        try await remoteEdit(library, snippet.id) { $0.template = try! TokenParser.parse("Remote body").document }
        await editor.refreshFromLibrary()
        XCTAssertEqual(editor.draft.name, "My unsaved name")
        XCTAssertTrue(editor.isDirty)
    }

    func testSavingATagEditKeepsARemoteBodyEditTheEditorNeverSaw() async throws {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: "Old body")
        let editor = openEditor(library, snippet)
        try await remoteEdit(library, snippet.id) { $0.template = try! TokenParser.parse("Remote body").document }
        editor.draft.tagsText = "work"
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let stored = try required(await library.snippet(id: snippet.id))
        XCTAssertEqual(stored.template.plainText, "Remote body", "a field the user did not touch keeps its stored value")
        XCTAssertEqual(stored.tags, ["work"])
    }

    func testWhenBothSidesEditedTheSameFieldTheUsersEditWins() async throws {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: "Old body")
        let editor = openEditor(library, snippet)
        try await remoteEdit(library, snippet.id) { $0.name = "Remote name"; $0.pinned = true }
        editor.draft.name = "Mine"
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let stored = try required(await library.snippet(id: snippet.id))
        XCTAssertEqual(stored.name, "Mine")
        XCTAssertTrue(stored.pinned, "a remote change to a field the editor does not edit survives")
        XCTAssertFalse(editor.isDirty)
    }

    func testTheLibraryModelRefreshesAnOpenCleanEditorWhenSyncApplies() async throws {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: "Old body")
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { _ in library })
        await model.open()
        await model.requestSelection(snippet.id)
        let handled = expectation(description: "change handled")
        handled.assertForOverFulfill = false
        model.onChangeHandled = { handled.fulfill() }
        try await remoteEdit(library, snippet.id) { $0.name = "Remote name" }
        await fulfillment(of: [handled], timeout: 5)
        XCTAssertEqual(model.editor?.draft.name, "Remote name")
    }
}
