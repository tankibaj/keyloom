import XCTest
@testable import Keyloom

@MainActor
final class LibraryViewModelTests: LibraryUITestCase {
    private func makeModel(_ library: SnippetLibrary) async -> LibraryViewModel {
        let model = LibraryViewModel(library: library)
        await model.refresh()
        return model
    }

    func testEmptyLibraryShowsEmptyStateWithNewSnippetRecovery() async throws {
        let model = await makeModel(try await openLibrary())
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyState, .emptyLibrary)
        XCTAssertEqual(model.counts, SidebarCounts(all: 0, recentlyUsed: 0, pinned: 0))
    }

    func testRowsCarryIconNameKeywordAndSidebarCounts() async throws {
        let library = try await openLibrary()
        try await seed(library, "Greeting", keyword: ";hi", tags: ["mail"])
        let pinned = try await seed(library, "Address", tags: ["mail", "home"], pinned: true)
        let model = await makeModel(library)

        XCTAssertEqual(model.rows.map(\.name), ["Address", "Greeting"], "pinned first, then by name")
        let greeting = try XCTUnwrap(model.rows.last)
        XCTAssertEqual(greeting.keyword, ";hi")
        XCTAssertEqual(greeting.icon, .emoji("🙂"))
        XCTAssertEqual(greeting.accessibilityLabel, "Greeting, keyword ;hi")
        XCTAssertEqual(model.rows.first?.accessibilityLabel, "Address, pinned")
        XCTAssertEqual(model.rows.first?.id, pinned.id)
        XCTAssertEqual(model.counts, SidebarCounts(all: 2, recentlyUsed: 0, pinned: 1))
        XCTAssertEqual(model.tags, [TagSummary(tag: "home", count: 1), TagSummary(tag: "mail", count: 2)])
    }

    func testFiltersPinnedRecentlyUsedAndTag() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "Alpha", tags: ["x"], pinned: true)
        let b = try await seed(library, "Beta", tags: ["y"])
        try await library.recordUsage(id: b.id)
        let model = await makeModel(library)

        model.sidebarItem = .pinned
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [a.id])
        model.sidebarItem = .recentlyUsed
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [b.id])
        XCTAssertEqual(model.counts.recentlyUsed, 1)
        model.sidebarItem = .tag("y")
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [b.id])
    }

    func testEmptyFilterExplainsAndShowAllRecovers() async throws {
        let library = try await openLibrary()
        try await seed(library, "Alpha")
        let model = await makeModel(library)
        model.sidebarItem = .pinned
        await model.refresh()
        XCTAssertEqual(model.emptyState, .emptyFilter(.pinned))
        await model.showAll()
        XCTAssertEqual(model.sidebarItem, .all)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNil(model.emptyState)
    }

    func testSearchMatchesNameKeywordTagAndBodyThenClearRecovers() async throws {
        let library = try await openLibrary()
        let name = try await seed(library, "Quarterly report")
        let keyword = try await seed(library, "Sign off", keyword: ";bye")
        let tag = try await seed(library, "Invoice", tags: ["finance"])
        let body = try await seed(library, "Standup", body: "yesterday I shipped")
        let model = await makeModel(library)

        for (query, expected) in [("quarterly", name.id), (";bye", keyword.id), ("financ", tag.id), ("shipped", body.id)] {
            model.query = query
            await model.refresh()
            XCTAssertEqual(model.rows.map(\.id), [expected], query)
        }
        model.query = "zzz"
        await model.refresh()
        XCTAssertEqual(model.emptyState, .noResults(query: "zzz"))
        await model.clearSearch()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertNil(model.emptyState)
    }

    func testDuplicateSelectsTheCopyAndKeywordedCopyStartsDisabled() async throws {
        let library = try await openLibrary()
        let original = try await seed(library, "Greeting", keyword: ";hi")
        let model = await makeModel(library)
        await model.duplicate(id: original.id)
        XCTAssertEqual(model.rows.count, 2)
        let copy = try XCTUnwrap(model.rows.first { $0.id != original.id })
        XCTAssertEqual(model.selection, copy.id)
        XCTAssertFalse(copy.enabled)
        XCTAssertNotEqual(copy.id, original.id)
    }

    func testTogglePinMovesRowAndUpdatesCounts() async throws {
        let library = try await openLibrary()
        try await seed(library, "Alpha")
        let beta = try await seed(library, "Beta")
        let model = await makeModel(library)
        await model.togglePin(id: beta.id)
        XCTAssertEqual(model.rows.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(model.counts.pinned, 1)
        await model.togglePin(id: beta.id)
        XCTAssertEqual(model.rows.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(model.counts.pinned, 0)
    }

    func testDeleteSelectsNextElsePreviousThenUndoRestores() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "A")
        let b = try await seed(library, "B")
        let c = try await seed(library, "C")
        let model = await makeModel(library)
        model.selection = b.id
        await model.delete(id: b.id)
        XCTAssertEqual(model.selection, c.id, "next row")
        await model.delete(id: c.id)
        XCTAssertEqual(model.selection, a.id, "no next, so the previous row")
        XCTAssertEqual(model.rows.map(\.id), [a.id])
        await model.undoLastDelete()
        XCTAssertEqual(model.rows.map(\.id), [a.id, c.id])
        XCTAssertEqual(model.selection, c.id, "the restored snippet is selected")
        await model.delete(id: a.id)
        await model.delete(id: c.id)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.emptyState, .emptyLibrary)
    }

    func testDeleteRegistersCommandZUndo() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "A")
        let model = await makeModel(library)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        undoManager.beginUndoGrouping()
        await model.delete(id: a.id)
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Delete Snippet")
        undoManager.undo()
        await model.idle()
        XCTAssertEqual(model.rows.map(\.id), [a.id])
    }

    func testChangeStreamRefreshesRowsFromOutsideTheModel() async throws {
        let library = try await openLibrary()
        let model = await makeModel(library)
        let observing = Task { await model.observeChanges() }
        try await seed(library, "From elsewhere")
        await library.close()
        await observing.value
        XCTAssertEqual(model.rows.map(\.name), ["From elsewhere"])
    }

    func testFailedActionSurfacesAnErrorWithoutSnippetText() async throws {
        let library = try await openLibrary()
        let a = try await seed(library, "Secret name")
        let model = await makeModel(library)
        await library.close()
        await model.delete(id: a.id)
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertFalse(message.contains("Secret"))
    }
}

final class DataLocationTests: XCTestCase {
    func testLaunchArgumentOverridesTheDataDirectory() {
        let url = DataLocation.resolve(arguments: ["Keyloom", "--keyloom-data-dir", "/tmp/kl-test"], isRunningTests: false)
        XCTAssertEqual(url.path, "/tmp/kl-test")
        XCTAssertEqual(DataLocation.databaseURL(in: url).lastPathComponent, "keyloom.sqlite")
    }

    func testDefaultIsApplicationSupportKeyloom() {
        let url = DataLocation.resolve(arguments: ["Keyloom"], isRunningTests: false)
        XCTAssertEqual(url.lastPathComponent, "Keyloom")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testUnderTestsTheRealLibraryIsNeverUsed() {
        let url = DataLocation.resolve(arguments: ["Keyloom"], isRunningTests: true)
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
