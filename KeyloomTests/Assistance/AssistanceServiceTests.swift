import XCTest
@testable import Keyloom

final class AssistanceServiceTests: XCTestCase {
    private let source = "Pls fix teh {clipboard} text. OTHER-PARAGRAPH-SECRET"
    private let selected = "fix teh {clipboard} text"

    private func makeRequest(revision: Int = 5, action: EditAction = .proofread) throws -> EditRequest {
        let doc = try TokenParser.parse(source).document
        let plain = doc.plainText
        let range = try XCTUnwrap(plain.range(of: selected))
        return EditRequest(action: action, document: doc, revision: revision, selection: try ValidatedUTF16Range(range, in: plain))
    }

    private func makeService(_ model: FakeModelFactory, policy: PolicyBox = PolicyBox()) -> AssistanceService {
        AssistanceService(policy: policy.source, sessions: model, makeID: { UUID(uuidString: "00000000-0000-0000-0000-00000000B001")! })
    }

    private let goodReply = "fix the ⟦1⟧ text"

    private func assertThrows(_ expected: AssistanceError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AssistanceError, expected, file: file, line: line)
        }
    }

    // MARK: Happy path and what reaches the model

    func testProposeReturnsAValidatedEditAndReleasesTheSession() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let edit = try await service.propose(makeRequest())
        XCTAssertEqual(edit.preview.proposedText, "fix the {clipboard} text")
        XCTAssertEqual(model.created, 1)
        XCTAssertEqual(model.responded, 1)
        await eventually("session released") { model.live == 0 }
        let hasPending = await service.hasPendingWork
        XCTAssertTrue(hasPending, "the unapplied suggestion is held until applied, cancelled or discarded")
    }

    func testModelReceivesOnlyMaskedSelectedProse() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        _ = try await makeService(model).propose(makeRequest())
        XCTAssertEqual(model.prompts, ["fix teh ⟦1⟧ text"])
        for text in model.prompts + model.instructions {
            XCTAssertFalse(text.contains("OTHER-PARAGRAPH-SECRET"))
            XCTAssertFalse(text.contains("clipboard"))
        }
    }

    // MARK: Policy gates the call

    func testNothingIsCreatedUnlessAssistanceIsReady() async throws {
        let states: [PolicySnapshot] = [
            PolicyBox.off,
            PolicySnapshot(assistanceOptIn: true, writingToolsOptIn: true, managed: .forbidden, modelAvailability: nil),
            PolicySnapshot(assistanceOptIn: false, writingToolsOptIn: true, managed: .notManaged, modelAvailability: nil),
            PolicySnapshot(assistanceOptIn: true, writingToolsOptIn: false, managed: .notManaged, modelAvailability: .downloading),
            PolicySnapshot(assistanceOptIn: true, writingToolsOptIn: false, managed: .notManaged, modelAvailability: .unsupportedLanguage),
            PolicySnapshot(assistanceOptIn: true, writingToolsOptIn: false, managed: .notManaged,
                           modelAvailability: .unavailable(.deviceNotEligible)),
        ]
        for snapshot in states {
            let model = FakeModelFactory(.reply(goodReply))
            let service = makeService(model, policy: PolicyBox(snapshot))
            let request = try makeRequest()
            await assertThrows(.notPermitted(snapshot.assistance)) { _ = try await service.propose(request) }
            XCTAssertEqual(model.created, 0, "\(snapshot.assistance)")
            XCTAssertEqual(model.responded, 0)
        }
    }

    func testInvalidSelectionNeverReachesTheModel() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let doc = try TokenParser.parse(source).document
        let empty = EditRequest(action: .shorten, document: doc, revision: 1, selection: try ValidatedUTF16Range(start: 3, end: 3, in: doc.plainText))
        await assertThrows(.emptySelection) { _ = try await service.propose(empty) }
        XCTAssertEqual(model.created, 0)
    }

    // MARK: Failures, no retries

    func testRejectedSuggestionIsNotRetriedAndLeavesNothingPending() async throws {
        let model = FakeModelFactory(.reply("fix the text"))
        let service = makeService(model)
        let request = try makeRequest()
        await assertThrows(.rejectedSuggestion(.tokenDropped)) { _ = try await service.propose(request) }
        XCTAssertEqual(model.created, 1)
        XCTAssertEqual(model.responded, 1)
        await eventually("session released") { model.live == 0 }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }

    func testModelErrorsAreTypedAndNotRetried() async throws {
        let cases: [(any Error, AssistanceError)] = [
            (ModelSessionError(failure: .unsupportedLanguage), .modelFailed(.unsupportedLanguage)),
            (ModelSessionError(failure: .contextTooLarge), .modelFailed(.contextTooLarge)),
            (ModelSessionError(failure: .refused), .modelFailed(.refused)),
            (URLError(.notConnectedToInternet), .modelFailed(.other)),
            (CancellationError(), .cancelled),
        ]
        for (thrown, expected) in cases {
            let model = FakeModelFactory(.fail(thrown))
            let service = makeService(model)
            let request = try makeRequest()
            await assertThrows(expected) { _ = try await service.propose(request) }
            XCTAssertEqual(model.created, 1)
            XCTAssertEqual(model.responded, 1)
            await eventually("session released") { model.live == 0 }
        }
    }

    func testSessionCreationFailureIsTypedAndNotRetried() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        model.failCreation = true
        let service = makeService(model)
        let request = try makeRequest()
        await assertThrows(.modelFailed(.other)) { _ = try await service.propose(request) }
        XCTAssertEqual(model.responded, 0)
    }

    // MARK: Apply

    func testApplyReturnsThePayloadOnceAndOnlyForTheCurrentState() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let request = try makeRequest(revision: 5)
        let edit = try await service.propose(request)
        let payload = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection)
        XCTAssertEqual(payload.document.plainText, "Pls fix the {clipboard} text. OTHER-PARAGRAPH-SECRET")
        XCTAssertEqual(payload.undo.document, request.document)
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
    }

    func testApplyRejectsAStaleRevisionOrSelectionAndDiscards() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let request = try makeRequest(revision: 5)
        let moved = try ValidatedUTF16Range(start: 0, end: 3, in: request.document.plainText)
        var edit = try await service.propose(request)
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 6, currentSelection: request.selection) }
        edit = try await service.propose(request)
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: moved) }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
    }

    func testApplyRefusesAnEditTheServiceDidNotIssue() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let request = try makeRequest()
        let service = makeService(model)
        _ = try await service.propose(request)
        let differentID = try EditPlanner.plan(request).proposal(from: goodReply, id: UUID())
        await assertThrows(.stale) { _ = try await service.apply(differentID, currentRevision: 5, currentSelection: request.selection) }
    }

    func testApplyIsRefusedOnceAssistanceIsNoLongerPermitted() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let policy = PolicyBox()
        let service = makeService(model, policy: policy)
        let request = try makeRequest()
        let edit = try await service.propose(request)
        policy.snapshot = PolicyBox.off
        await assertThrows(.notPermitted(.off)) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }

    // MARK: Cancellation and fencing

    private func startGated(_ service: AssistanceService, _ model: FakeModelFactory, _ request: EditRequest)
        async -> Task<ProposedEdit, any Error> {
        let task = Task { try await service.propose(request) }
        await model.gate.waitForRequests(1)
        return task
    }

    private func outcome(_ task: Task<ProposedEdit, any Error>) async -> AssistanceError? {
        do {
            _ = try await task.value
            return nil
        } catch {
            return error as? AssistanceError
        }
    }

    func testCancelReturnsImmediatelyAndALateReplyIsDiscarded() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let request = try makeRequest()
        let task = await startGated(service, model, request)
        await service.cancel()
        let result = await outcome(task)
        XCTAssertEqual(result, .cancelled, "returns without waiting for the model")
        await model.gate.release(goodReply)
        await eventually("session released") { model.live == 0 }
        XCTAssertEqual(model.returnedCancelled, [true], "the generation task was cancelled")
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending, "a late reply must not become a suggestion")
    }

    func testDisablingAssistanceCancelsPendingWork() async throws {
        let model = FakeModelFactory(.gated)
        let policy = PolicyBox()
        let service = makeService(model, policy: policy)
        let task = await startGated(service, model, try makeRequest())
        policy.snapshot = PolicyBox.off
        await service.policyDidChange()
        let result = await outcome(task)
        XCTAssertEqual(result, .cancelled)
        await model.gate.release(goodReply)
        await eventually("session released") { model.live == 0 }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }

    func testReplyArrivingAfterDisablingIsFencedEvenWithoutANotification() async throws {
        let model = FakeModelFactory(.gated)
        let policy = PolicyBox()
        let service = makeService(model, policy: policy)
        let task = await startGated(service, model, try makeRequest())
        policy.snapshot = PolicyBox.off
        await model.gate.release(goodReply)
        let result = await outcome(task)
        XCTAssertEqual(result, .notPermitted(.off))
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }

    func testPolicyChangeDiscardsAnUnappliedSuggestion() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let request = try makeRequest()
        let edit = try await service.propose(request)
        await service.policyDidChange()
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
    }

    func testClosingTheEditorCancelsAndDiscards() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let task = await startGated(service, model, try makeRequest())
        await service.editorClosed()
        let result = await outcome(task)
        XCTAssertEqual(result, .cancelled)

        let instant = FakeModelFactory(.reply(goodReply))
        let second = makeService(instant)
        let request = try makeRequest()
        let edit = try await second.propose(request)
        await second.editorClosed()
        let hasPending = await second.hasPendingWork
        XCTAssertFalse(hasPending)
        await assertThrows(.stale) { _ = try await second.apply(edit, currentRevision: 5, currentSelection: request.selection) }
        await model.gate.release(goodReply)
    }

    func testAnEditorChangeDuringGenerationMakesTheReplyStale() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let request = try makeRequest(revision: 5)
        let task = await startGated(service, model, request)
        await service.editorStateChanged(revision: 6, selection: request.selection)
        let result = await outcome(task)
        XCTAssertEqual(result, .cancelled)
        await model.gate.release(goodReply)
    }

    func testAnUnchangedEditorStateKeepsTheWorkAlive() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let request = try makeRequest(revision: 5)
        let task = await startGated(service, model, request)
        await service.editorStateChanged(revision: 5, selection: request.selection)
        await model.gate.release(goodReply)
        let result = await outcome(task)
        XCTAssertNil(result)
    }

    func testAnEditorChangeDiscardsAnUnappliedSuggestion() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let request = try makeRequest(revision: 5)
        let edit = try await service.propose(request)
        await service.editorStateChanged(revision: 5, selection: try ValidatedUTF16Range(start: 0, end: 3, in: request.document.plainText))
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
    }

    func testANewRequestSupersedesTheOldOne() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let request = try makeRequest()
        let first = await startGated(service, model, request)
        let second = Task { try await service.propose(request) }
        await model.gate.waitForRequests(2)
        let firstResult = await outcome(first)
        XCTAssertEqual(firstResult, .cancelled)
        await model.gate.release("ignored by the superseded request")
        await model.gate.release(goodReply)
        let edit = try await second.value
        XCTAssertEqual(edit.preview.proposedText, "fix the {clipboard} text")
        XCTAssertEqual(model.created, 2)
    }

    func testUserCancelDiscardsAnUnappliedSuggestion() async throws {
        let model = FakeModelFactory(.reply(goodReply))
        let service = makeService(model)
        let request = try makeRequest()
        let edit = try await service.propose(request)
        await service.cancel()
        await assertThrows(.stale) { _ = try await service.apply(edit, currentRevision: 5, currentSelection: request.selection) }
    }

    func testCallerCancellationCancelsTheGeneration() async throws {
        let model = FakeModelFactory(.gated)
        let service = makeService(model)
        let task = await startGated(service, model, try makeRequest())
        task.cancel()
        let result = await outcome(task)
        XCTAssertEqual(result, .cancelled)
        await model.gate.release(goodReply)
        await eventually("session released") { model.live == 0 }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }

    // MARK: Nothing sensitive in errors

    func testErrorsNeverCarryPromptOrTokenText() async throws {
        let model = FakeModelFactory(.reply("fix the text"))
        let service = makeService(model)
        let request = try makeRequest()
        do {
            _ = try await service.propose(request)
            XCTFail("expected a rejection")
        } catch {
            let text = String(describing: error) + String(reflecting: error)
            XCTAssertFalse(text.contains("teh"))
            XCTAssertFalse(text.contains("clipboard"))
            XCTAssertFalse(text.contains("OTHER-PARAGRAPH-SECRET"))
        }
    }
}
