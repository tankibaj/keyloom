import XCTest
@testable import Keyloom

@MainActor
final class TrashTests: LibraryUITestCase {
    private func makeModel(_ library: SnippetLibrary) async -> LibraryViewModel {
        let model = LibraryViewModel(library: library)
        await model.refresh()
        return model
    }

    func testRecentlyDeletedListsDeletedSnippetsAndRestoreBringsThemBack() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "A", keyword: ";a")
        try await seed(library, "B")
        let model = await makeModel(library)
        await model.delete(id: a.id)

        model.sidebarItem = .recentlyDeleted
        await model.refresh()
        XCTAssertEqual(model.deletedRows.map(\.name), ["A"])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.emptyState)

        await model.restoreDeleted(id: a.id)
        XCTAssertTrue(model.deletedRows.isEmpty)
        XCTAssertEqual(model.emptyState, .emptyTrash)
        XCTAssertNil(model.notice, "restored as it was")
        let restored = await library.snippet(id: a.id)
        XCTAssertEqual(restored?.keyword, ";a")
        XCTAssertEqual(restored?.enabled, true)
    }

    func testRestoreWhenTheKeywordWasTakenComesBackDisabledAndSaysSo() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "Old owner", keyword: ";x")
        let model = await makeModel(library)
        await model.delete(id: a.id)
        try await seed(library, "New owner", keyword: ";x")
        model.sidebarItem = .recentlyDeleted
        await model.refresh()

        await model.restoreDeleted(id: a.id)
        let restored = await library.snippet(id: a.id)
        XCTAssertEqual(restored?.enabled, false)
        XCTAssertEqual(model.notice, "“Old owner” is back with expansion off: another snippet now uses ;x.")
    }

    func testEmptyTrashSaysSo() async throws {
        let model = await makeModel(try await openLibrary())
        model.sidebarItem = .recentlyDeleted
        await model.refresh()
        XCTAssertEqual(model.emptyState, .emptyTrash)
    }
}

/// The whole CRUD loop through the app model and a real library, then a relaunch on the same folder.
@MainActor
final class CRUDFlowTests: LibraryUITestCase {
    func testCreateRenameDuplicatePinDeleteUndoRecoverAndRelaunch() async throws {
        let directory = try makeDirectory()
        let model = AppModel(dataDirectory: directory, openLibrary: { [self] in try await openLibrary(at: $0) })
        await model.open()
        let library = try XCTUnwrap(model.library)
        let list = try XCTUnwrap(model.libraryModel)

        // Create
        await model.requestNewSnippet()
        let editor = try XCTUnwrap(model.editor)
        editor.draft.name = "Follow-up"
        editor.draft.icon = .emoji("✉️")
        editor.draft.keyword = ";fu"
        editor.draft.tagsText = "mail"
        editor.draft.body = try document("Hi {argument name=\"who\"},{cursor}")
        let saved = await model.saveEditor()
        XCTAssertTrue(saved)
        await list.refresh()
        let id = try XCTUnwrap(list.rows.first?.id)
        XCTAssertEqual(list.selection, id)
        let matchedCreated = matched(library, ";fu")
        XCTAssertEqual(matchedCreated, id)

        // Rename and re-key: same ID, indexes follow
        editor.draft.name = "Follow up (long)"
        editor.draft.keyword = ";flw"
        let renamed = await model.saveEditor()
        XCTAssertTrue(renamed)
        let afterRename = await library.snippet(id: id)
        XCTAssertEqual(afterRename?.name, "Follow up (long)")
        XCTAssertEqual(afterRename?.revision, 2)
        XCTAssertNil(matched(library, ";fu"), "the old keyword stops expanding")
        XCTAssertEqual(matched(library, ";flw"), id)
        list.query = "long"
        await list.refresh()
        XCTAssertEqual(list.rows.map(\.id), [id], "search sees the new name")
        list.query = ""
        await list.refresh()

        // Duplicate: new ID, original untouched, the copy's keyword is off
        await list.duplicate(id: id)
        XCTAssertEqual(list.rows.count, 2)
        let copyID = try XCTUnwrap(list.rows.first { $0.id != id }?.id)
        XCTAssertEqual(list.selection, copyID)
        XCTAssertEqual(matched(library, ";flw"), id)

        // Pin
        await list.togglePin(id: copyID)
        XCTAssertEqual(list.rows.first?.id, copyID)

        // Delete, undo (Cmd-Z), delete again, recover from Recently Deleted
        await list.delete(id: id)
        XCTAssertEqual(list.rows.map(\.id), [copyID])
        XCTAssertNil(matched(library, ";flw"))
        await list.undoLastDelete()
        XCTAssertEqual(Set(list.rows.map(\.id)), [id, copyID])
        XCTAssertEqual(matched(library, ";flw"), id)
        await list.delete(id: id)
        list.sidebarItem = .recentlyDeleted
        await list.refresh()
        await list.restoreDeleted(id: id)
        list.sidebarItem = .all
        await list.refresh()
        XCTAssertEqual(Set(list.rows.map(\.id)), [id, copyID])

        // Relaunch on the same folder: stable IDs, indexes rebuilt from disk
        await library.close()
        let relaunched = try await openLibrary(at: directory)
        let all = await relaunched.allSnippets()
        XCTAssertEqual(Set(all.map(\.id)), [id, copyID])
        XCTAssertEqual(matched(relaunched, ";flw"), id)
        let found = await relaunched.search(query: "long")
        guard case .results(let hits) = found else { return XCTFail("expected a hit") }
        XCTAssertEqual(Set(hits.map(\.snippet.id)), [id, copyID], "the copy carries the original's name, so both match")
    }

    private func matched(_ library: SnippetLibrary, _ typed: String) -> UUID? {
        library.keywordMatcher.invalidate()
        return library.keywordMatcher.feed(typed)?.snippetID
    }
}
