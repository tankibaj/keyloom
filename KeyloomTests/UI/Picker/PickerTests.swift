import XCTest
@testable import Keyloom

@MainActor
final class FakePickerPanel: PickerPanelPresenting {
    private(set) var shown: [PickerModel] = []
    private(set) var hideCount = 0

    func show(_ model: PickerModel) { shown.append(model) }
    func hide() { hideCount += 1 }
}

@MainActor
final class FakeFocusRestorer: FocusRestoring {
    private(set) var remembered = 0
    private(set) var restored = 0

    func rememberFrontmost() { remembered += 1 }
    func restore() { restored += 1 }
}

/// The picker over the real host, library and insertion path; only the window, the previous-app handle and the
/// OS boundaries behind the host are fakes.
@MainActor
class PickerTestCase: LibraryUITestCase {
    var library: SnippetLibrary!
    var panel: FakePickerPanel!
    var focus: FakeFocusRestorer!
    var prompter: FakePrompter!
    var coordinator: PickerCoordinator!
    var harness: UIHostHarness!

    /// `seed` runs against the library before the host exists, so the keyword index is complete.
    func makePicker(seed body: (SnippetLibrary) async throws -> Void) async throws {
        library = try await openTestLibrary()
        try await body(library)
        panel = FakePickerPanel()
        focus = FakeFocusRestorer()
        prompter = FakePrompter()
        coordinator = PickerCoordinator(library: library, panel: panel, focus: focus, prompter: prompter,
                                        environment: { RenderEnvironment(date: Date(timeIntervalSince1970: 0), timeZone: .gmt, locale: Locale(identifier: "en_US"), makeUUID: { UUID() }, clipboardText: { "clip" }) })
        harness = makeHarness(library: library, prompter: prompter, picker: coordinator)
        coordinator.attach(harness.controller)
    }

    @discardableResult
    func openPicker() async throws -> PickerModel {
        harness.controller.openPicker()
        let model = try XCTUnwrap(coordinator.model)
        await model.idle()
        return model
    }
}

final class PickerSearchTests: PickerTestCase {
    func testOpeningCapturesTheDestinationBeforeTheWindowAndRemembersIt() async throws {
        try await makePicker { try await self.seed($0, "Hello") }
        let model = try await openPicker()
        XCTAssertNotNil(model.destination)
        XCTAssertEqual(panel.shown.count, 1)
        XCTAssertEqual(focus.remembered, 1, "The frontmost app is noted before Keyloom activates")
        XCTAssertTrue(harness.destination.writes.isEmpty, "Opening never touches the destination")
    }

    func testAnEmptyQueryListsPinnedFirstThenByNameWithTheFirstRowSelected() async throws {
        try await makePicker { library in
            try await self.seed(library, "Bravo")
            try await self.seed(library, "Alpha")
            try await self.seed(library, "Zulu", pinned: true)
        }
        let model = try await openPicker()
        XCTAssertEqual(model.rows.map(\.name), ["Zulu", "Alpha", "Bravo"])
        XCTAssertEqual(model.selection, model.rows.first?.id)
    }

    func testTypingFiltersByNameKeywordAndBody() async throws {
        try await makePicker { library in
            try await self.seed(library, "Greeting", keyword: ";hi", body: "Hello there")
            try await self.seed(library, "Signature", body: "Best regards")
        }
        let model = try await openPicker()
        model.query = "regards"
        await model.idle()
        XCTAssertEqual(model.rows.map(\.name), ["Signature"])
        XCTAssertEqual(model.selection, model.rows.first?.id)
        model.query = ";hi"
        await model.idle()
        XCTAssertEqual(model.rows.map(\.name), ["Greeting"])
    }

    func testAnOlderSearchNeverOverwritesTheNewerQuery() async throws {
        try await makePicker { library in
            try await self.seed(library, "Alpha")
            try await self.seed(library, "Beta")
        }
        let model = try await openPicker()
        model.query = "alp"
        model.query = "bet"
        await model.idle()
        XCTAssertEqual(model.rows.map(\.name), ["Beta"])
    }

    func testEmptyStatesNameTheirCauseAndClearingRecovers() async throws {
        try await makePicker { _ in }
        var model = try await openPicker()
        XCTAssertEqual(model.emptyState, .emptyLibrary)
        XCTAssertNil(model.selection)
        try await seed(library, "Alpha")
        model = try await openPicker()
        model.query = "zzz"
        await model.idle()
        XCTAssertEqual(model.emptyState, .noResults(query: "zzz"))
        model.query = ""
        await model.idle()
        XCTAssertNil(model.emptyState)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testArrowsMoveTheSelectionAndStopAtTheEnds() async throws {
        try await makePicker { library in
            for name in ["A", "B", "C"] { try await self.seed(library, name) }
        }
        let model = try await openPicker()
        let ids = model.rows.map(\.id)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, ids[0])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, ids[2])
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, ids[1])
    }

    func testPreviewShowsTheRenderedSelectionWithStandInsForArguments() async throws {
        try await makePicker { library in
            try await self.seed(library, "Alpha", body: #"Hi {argument name="who"}"#)
            try await self.seed(library, "Beta", body: #"Hi {argument name="who" default="Sam"}"#)
        }
        let model = try await openPicker()
        await model.idle()
        guard case .rendered(let first)? = model.preview else { return XCTFail("no preview") }
        XCTAssertEqual(first.plainText, "Hi ‹who›")
        model.moveSelection(by: 1)
        await model.idle()
        guard case .rendered(let second)? = model.preview else { return XCTFail("no preview") }
        XCTAssertEqual(second.plainText, "Hi Sam")
    }
}

final class PickerActionTests: PickerTestCase {
    func testInsertWritesToTheCapturedDestinationRecordsUsageAndHidesThePanel() async throws {
        var seeded: Snippet!
        try await makePicker { seeded = try await self.seed($0, "Hello", body: "Hello") }
        let model = try await openPicker()
        await model.insertSelected()
        XCTAssertEqual(harness.destination.text, "Dear Hello tail")
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(harness.controller.status.lastOutcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        let used = await library.snippet(id: seeded.id)?.lastUsedAt
        XCTAssertNotNil(used, "The picker records usage through the host insert path")
        XCTAssertEqual(harness.pasteboard.plain, UIHostHarness.userClipboard, "Plain insertion never touches the clipboard")
    }

    func testInsertAsksForArgumentsThenInsertsTheAnswers() async throws {
        try await makePicker { try await self.seed($0, "Hello", body: #"Hi {argument name="who"} and {argument name="who"}"#) }
        prompter.answers = ["who": "Ada"]
        let model = try await openPicker()
        await model.insertSelected()
        XCTAssertEqual(prompter.requests.count, 1)
        XCTAssertEqual(prompter.requests.first?.map(\.name), ["who"])
        XCTAssertEqual(harness.destination.text, "Dear Hi Ada and Ada tail")
    }

    func testCancellingThePromptLeavesTheDestinationAloneAndReturnsFocus() async throws {
        var seeded: Snippet!
        try await makePicker { seeded = try await self.seed($0, "Hello", body: #"Hi {argument name="who"}"#) }
        prompter.answers = nil
        let model = try await openPicker()
        await model.insertSelected()
        XCTAssertEqual(harness.destination.text, "Dear  tail")
        XCTAssertTrue(harness.destination.writes.isEmpty)
        XCTAssertEqual(focus.restored, 1)
        let used = await library.snippet(id: seeded.id)?.lastUsedAt
        XCTAssertNil(used)
    }

    func testARefusedInsertLeavesTextIntactAndReopensThePickerOfferingCopy() async throws {
        try await makePicker { try await self.seed($0, "Hello", body: "Hello") }
        let model = try await openPicker()
        harness.destination.token = FocusToken(pid: 200, element: 9)  // the user moved to another field meanwhile
        await model.insertSelected()
        XCTAssertEqual(harness.destination.text, "Dear  tail")
        XCTAssertEqual(panel.shown.count, 2, "The picker comes back so the user can Copy")
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.canCopy)
    }

    func testCopyPutsTheSnippetOnTheClipboardAndHidesWithoutInserting() async throws {
        try await makePicker { try await self.seed($0, "Hello", body: "Hello") }
        let model = try await openPicker()
        await model.copySelected()
        XCTAssertEqual(harness.pasteboard.plain, "Hello")
        XCTAssertEqual(harness.controller.status.lastOutcome, .copied)
        XCTAssertEqual(harness.destination.text, "Dear  tail")
        XCTAssertEqual(panel.hideCount, 1)
    }

    func testWithoutADestinationInsertIsOffButCopyWorks() async throws {
        try await makePicker { try await self.seed($0, "Hello", body: "Hello") }
        harness.environment.isSecureInputActive = true
        let model = try await openPicker()
        XCTAssertNil(model.destination)
        XCTAssertFalse(model.canInsert)
        XCTAssertNotNil(model.notice, "Says why only Copy is offered")
        await model.insertSelected()
        XCTAssertTrue(harness.destination.writes.isEmpty)
        XCTAssertEqual(panel.hideCount, 0)
        await model.copySelected()
        XCTAssertEqual(harness.pasteboard.plain, "Hello")
    }

    func testEscapeHidesAndReturnsFocusWithoutTouchingAnything() async throws {
        try await makePicker { try await self.seed($0, "Hello") }
        let model = try await openPicker()
        model.cancel()
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(focus.restored, 1)
        XCTAssertTrue(harness.destination.writes.isEmpty)
    }

    func testOpeningAgainReplacesThePreviousSession() async throws {
        try await makePicker { try await self.seed($0, "Hello") }
        let first = try await openPicker()
        let second = try await openPicker()
        XCTAssertFalse(first === second)
        XCTAssertTrue(coordinator.model === second)
    }
}
