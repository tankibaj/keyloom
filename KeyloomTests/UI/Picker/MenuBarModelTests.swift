import XCTest
@testable import Keyloom

final class MenuBarModelTests: PickerTestCase {
    private var menu: MenuBarModel!

    private func makeMenu(seed body: (SnippetLibrary) async throws -> Void) async throws {
        try await makePicker(seed: body)
        menu = MenuBarModel(library: library, host: harness.controller, picker: coordinator)
        await menu.refresh()
    }

    func testListsPinnedSnippetsAndRecentlyUsedOnes() async throws {
        try await makeMenu { library in
            try await self.seed(library, "Pinned one", pinned: true)
            let used = try await self.seed(library, "Used one")
            try await self.seed(library, "Plain")
            try await library.recordUsage(id: used.id)
        }
        XCTAssertEqual(menu.pinned.map(\.name), ["Pinned one"])
        XCTAssertEqual(menu.recents.map(\.name), ["Used one"])
    }

    func testSearchFiltersBothLists() async throws {
        try await makeMenu { library in
            try await self.seed(library, "Sign off", body: "Best", pinned: true)
            try await self.seed(library, "Hello", body: "Hi", pinned: true)
        }
        menu.query = "sign"
        await menu.refresh()
        XCTAssertEqual(menu.pinned.map(\.name), ["Sign off"])
        menu.query = "nothing here"
        await menu.refresh()
        XCTAssertTrue(menu.pinned.isEmpty)
        XCTAssertTrue(menu.recents.isEmpty)
    }

    func testPauseToggleReachesTheHost() async throws {
        try await makeMenu { _ in }
        menu.isPaused = true
        XCTAssertTrue(harness.controller.status.isPaused)
        XCTAssertTrue(harness.controller.inputHost.isPaused)
        menu.isPaused = false
        XCTAssertFalse(harness.controller.inputHost.isPaused)
    }

    func testWithoutAccessibilityOnlyLibrarySettingsAndQuitRemain() async throws {
        try await makeMenu { _ in }
        XCTAssertTrue(menu.showsExpansionCommands)
        harness.permissions.status = PermissionStatus(accessibility: false)
        harness.controller.refreshPermissions()
        XCTAssertFalse(menu.showsExpansionCommands, "New Snippet and Open Picker are hidden until Accessibility is granted")
    }

    func testStatusFollowsPermissionThenPause() async throws {
        try await makeMenu { _ in }
        XCTAssertEqual(menu.status, .on)
        XCTAssertTrue(menu.isExpanding)
        menu.isExpanding = false
        XCTAssertEqual(menu.status, .paused)
        harness.permissions.status = PermissionStatus(accessibility: false)
        harness.controller.refreshPermissions()
        XCTAssertEqual(menu.status, .needsAccessibility, "a missing grant outranks pause")
        XCTAssertTrue(menu.needsAccessibility)
        XCTAssertFalse(menu.isExpanding)
    }

    func testRowsAreNumberedAcrossSectionsUpToNine() {
        let rows = (1...12).map { SnippetRow(Snippet(name: "S\($0)", icon: .emoji("x"), keyword: "::s\($0)", template: Document(paragraphs: []), createdAt: Date())) }
        let items = MenuBarModel.numbered(Array(rows[..<3]), offset: 0) + MenuBarModel.numbered(Array(rows[3...]), offset: 3)
        XCTAssertEqual(items.prefix(9).compactMap(\.number), Array(1...9))
        XCTAssertTrue(items.dropFirst(9).allSatisfy { $0.number == nil }, "no shortcut past ⌘9")
        XCTAssertEqual(items.first?.shortcutHint, "⌘1")
        XCTAssertEqual(items.first?.chip, "::s1")
    }

    func testAShortcutConflictIsSurfacedWithTheCombination() async throws {
        try await makeMenu { _ in }
        harness.hotKeys.results[.defaultShortcut] = .conflict
        harness.controller.start()
        let warning = try XCTUnwrap(menu.shortcutWarning)
        XCTAssertTrue(warning.contains("⌃⌥Space"), warning)
    }

    func testNoWarningWhenTheShortcutRegistered() async throws {
        try await makeMenu { _ in }
        harness.controller.start()
        XCTAssertNil(menu.shortcutWarning)
    }

    func testPickingAPinnedSnippetInsertsIntoTheFieldCapturedAtClickTime() async throws {
        var seeded: Snippet!
        try await makeMenu { seeded = try await self.seed($0, "Hello", body: "Hello", pinned: true) }
        await menu.insert(seeded.id)
        XCTAssertEqual(harness.destination.text, "Dear Hello tail")
        await harness.controller.waitForUsageRecording()
        let used = await library.snippet(id: seeded.id)?.lastUsedAt
        XCTAssertNotNil(used)
        XCTAssertTrue(panel.shown.isEmpty, "No picker window opens for a menu insert")
    }

    func testWithoutAUsableFieldThePickedSnippetIsCopiedAndTheMenuSaysSo() async throws {
        var seeded: Snippet!
        try await makeMenu { seeded = try await self.seed($0, "Hello", body: "Hello", pinned: true) }
        harness.environment.isSecureInputActive = true
        await menu.insert(seeded.id)
        XCTAssertEqual(harness.pasteboard.plain, "Hello")
        XCTAssertEqual(harness.destination.text, "Dear  tail")
        XCTAssertNotNil(menu.notice)
    }

    func testARefusedInsertOffersCopyFromTheMenu() async throws {
        var seeded: Snippet!
        try await makeMenu { seeded = try await self.seed($0, "Hello", body: "Hello", pinned: true) }
        harness.destination.onActivate = { [destination = harness.destination] _ in destination.text = "Changed" }
        await menu.insert(seeded.id)
        XCTAssertEqual(harness.destination.text, "Changed")
        XCTAssertTrue(menu.hasCopyOffer)
        XCTAssertNotNil(menu.notice)
        menu.copyRefused()
        XCTAssertEqual(harness.pasteboard.plain, "Hello")
        XCTAssertFalse(menu.hasCopyOffer)
    }

    func testCancellingTheArgumentPromptReturnsFocusAndInsertsNothing() async throws {
        var seeded: Snippet!
        try await makeMenu { seeded = try await self.seed($0, "Hello", body: #"Hi {argument name="who"}"#, pinned: true) }
        prompter.answers = nil
        await menu.insert(seeded.id)
        XCTAssertTrue(harness.destination.writes.isEmpty)
        XCTAssertEqual(focus.restored, 1)
    }

    func testOpenPickerGoesThroughTheHostCaptureAndShowsThePicker() async throws {
        try await makeMenu { try await self.seed($0, "Hello") }
        menu.openPicker()
        XCTAssertEqual(panel.shown.count, 1)
    }
}
