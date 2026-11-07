import XCTest
@testable import Keyloom

/// The window is the only fake: it records what the coordinator showed and lets a test act while it is open.
@MainActor
final class FakePromptPresenter: PromptPresenting {
    private(set) var shown: [ArgumentPromptModel] = []
    private(set) var closeCount = 0
    /// Runs when the prompt opens: the user's reaction.
    var onShow: ((ArgumentPromptModel) -> Void)?

    func show(_ model: ArgumentPromptModel) {
        shown.append(model)
        onShow?(model)
    }

    func close() { closeCount += 1 }
}

@MainActor
final class ArgumentPromptModelTests: XCTestCase {
    private func requirement(_ name: String, default value: String? = nil, choices: [String] = []) -> ArgumentRequirement {
        ArgumentRequirement(name: name, defaultValue: value, choices: choices)
    }

    func testRepeatedNamesAreAskedOnce() {
        let model = ArgumentPromptModel(title: "Follow up", requirements: [requirement("who"), requirement("when"), requirement("who")])
        XCTAssertEqual(model.fields.map(\.name), ["who", "when"])
    }

    func testDefaultsArePrefilledAndAChoiceWithoutDefaultStartsOnItsFirstOption() {
        let model = ArgumentPromptModel(title: "T", requirements: [
            requirement("who", default: "Sam"), requirement("tone", choices: ["warm", "formal"]),
            requirement("day", default: "Fri", choices: ["Mon", "Fri"])])
        XCTAssertEqual(model.fields.map(\.value), ["Sam", "warm", "Fri"])
        XCTAssertEqual(model.fields.map(\.isChoice), [false, true, true])
    }

    func testConfirmReturnsEveryAnswerByName() {
        let model = ArgumentPromptModel(title: "T", requirements: [requirement("who"), requirement("tone", choices: ["warm", "formal"])])
        var result: [String: String]??
        model.onFinish = { result = $0 }
        model.setValue("Ada", for: "who")
        model.setValue("formal", for: "tone")
        model.confirm()
        XCTAssertEqual(result, ["who": "Ada", "tone": "formal"])
    }

    func testFreeTextWithoutDefaultMustBeFilledBeforeConfirm() {
        let model = ArgumentPromptModel(title: "T", requirements: [requirement("who")])
        var finished = false
        model.onFinish = { _ in finished = true }
        XCTAssertFalse(model.canConfirm)
        model.confirm()
        XCTAssertFalse(finished, "Confirm with a missing answer must do nothing")
        model.setValue("   ", for: "who")
        XCTAssertFalse(model.canConfirm, "A blank answer is still missing")
        model.setValue("Ada", for: "who")
        XCTAssertTrue(model.canConfirm)
    }

    func testClearingAPrefilledDefaultIsAllowed() {
        let model = ArgumentPromptModel(title: "T", requirements: [requirement("who", default: "Sam")])
        model.setValue("", for: "who")
        XCTAssertTrue(model.canConfirm)
    }

    func testAChoiceOutsideItsOptionsIsRejected() {
        let model = ArgumentPromptModel(title: "T", requirements: [requirement("tone", choices: ["warm", "formal"])])
        model.setValue("angry", for: "tone")
        XCTAssertEqual(model.fields[0].value, "warm", "An unknown option is ignored, the pick stays valid")
        XCTAssertTrue(model.canConfirm)
        model.setValue("formal", for: "tone")
        XCTAssertEqual(model.fields[0].value, "formal")
    }

    func testCancelReturnsNilAndFinishesOnlyOnce() {
        let model = ArgumentPromptModel(title: "T", requirements: [requirement("who", default: "Sam")])
        var results: [[String: String]?] = []
        model.onFinish = { results.append($0) }
        model.cancel()
        model.confirm()
        model.cancel()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }
}

@MainActor
final class ArgumentPromptCoordinatorTests: LibraryUITestCase {
    private var presenter: FakePromptPresenter!
    private var coordinator: ArgumentPromptCoordinator!

    override func setUp() async throws {
        presenter = FakePromptPresenter()
        coordinator = ArgumentPromptCoordinator(presenter: presenter, title: { _ in "Follow up" })
    }

    private let needs = [ArgumentRequirement(name: "who", defaultValue: "Sam", choices: [])]

    func testConfirmResumesWithTheAnswersAndClosesTheWindow() async {
        presenter.onShow = { $0.setValue("Ada", for: "who"); $0.confirm() }
        let answers = await coordinator.promptForArguments(for: UUID(), requirements: needs)
        XCTAssertEqual(answers, ["who": "Ada"])
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testCancelResumesWithNilAndClosesTheWindow() async {
        presenter.onShow = { $0.cancel() }
        let answers = await coordinator.promptForArguments(for: UUID(), requirements: needs)
        XCTAssertNil(answers)
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testTaskCancellationReturnsNilPromptlyWhileThePromptIsOpen() async {
        let shown = expectation(description: "prompt shown")
        presenter.onShow = { _ in shown.fulfill() }
        let task = Task { await coordinator.promptForArguments(for: UUID(), requirements: needs) }
        await fulfillment(of: [shown], timeout: 5)
        task.cancel()
        let answers = await task.value
        XCTAssertNil(answers)
        XCTAssertEqual(presenter.closeCount, 1, "The window must close when the host cancels")
    }

    func testAlreadyCancelledTaskNeverShowsAWindow() async {
        let task = Task { () -> [String: String]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.promptForArguments(for: UUID(), requirements: needs)
        }
        let answers = await task.value
        XCTAssertNil(answers)
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testASecondPromptWhileOneIsOpenIsRefused() async {
        let shown = expectation(description: "first shown")
        presenter.onShow = { _ in shown.fulfill() }
        let first = Task { await coordinator.promptForArguments(for: UUID(), requirements: needs) }
        await fulfillment(of: [shown], timeout: 5)
        let second = await coordinator.promptForArguments(for: UUID(), requirements: needs)
        XCTAssertNil(second)
        XCTAssertEqual(presenter.shown.count, 1)
        presenter.shown[0].cancel()
        _ = await first.value
    }

    /// The real host contract: a typed keyword with a repeated argument asks once, and the answer lands in the field.
    func testTypedKeywordWithRepeatedArgumentPromptsOnceThenInsertsThroughTheHost() async throws {
        let library = try await openTestLibrary()
        try await seed(library, "Follow up", keyword: ";fu",
                       body: #"Hi {argument name="who" default="Sam"}, bye {argument name="who"}"#)
        let harness = makeHarness(library: library, prompter: coordinator, picker: FakePicker(), prefix: "", typed: ";fu", suffix: "")
        harness.controller.start()
        presenter.onShow = { model in
            XCTAssertEqual(model.fields.map(\.name), ["who"])
            XCTAssertEqual(model.fields.first?.value, "Sam")
            model.setValue("Ada", for: "who")
            model.confirm()
        }
        for unit in ";fu".utf16 {
            harness.controller.inputHost.handleKeyDown(origin: .physical) { KeyContent(units: [unit], keyCode: 0, hasCommandOrControl: false) }
        }
        await harness.controller.expansionTask?.value
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(harness.destination.text, "Hi Ada, bye Ada")
    }

    func testCancelledPromptLeavesTheTypedKeywordAndReturnsFocus() async throws {
        let library = try await openTestLibrary()
        try await seed(library, "Follow up", keyword: ";fu", body: #"Hi {argument name="who"}"#)
        let harness = makeHarness(library: library, prompter: coordinator, picker: FakePicker(), prefix: "", typed: ";fu", suffix: "")
        harness.controller.start()
        presenter.onShow = { $0.cancel() }
        for unit in ";fu".utf16 {
            harness.controller.inputHost.handleKeyDown(origin: .physical) { KeyContent(units: [unit], keyCode: 0, hasCommandOrControl: false) }
        }
        await harness.controller.expansionTask?.value
        XCTAssertEqual(harness.destination.text, ";fu")
        XCTAssertTrue(harness.destination.writes.isEmpty)
        XCTAssertGreaterThanOrEqual(harness.destination.activateCount, 1, "Focus goes back to the destination app")
    }
}
