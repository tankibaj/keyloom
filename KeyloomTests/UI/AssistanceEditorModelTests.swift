import AppKit
import XCTest
@testable import Keyloom

/// The editor's on-device assistance action over the real planner, service, policy and rich-text view; only the
/// language model (and the OS availability query) is a fake.
@MainActor
final class AssistanceEditorModelTests: LibraryUITestCase {
    struct Rig {
        let editor: EditorViewModel
        let textView: NSTextView
        let model: AssistanceEditorModel
        let factory: FakeModelFactory
        let policy: WritingAssistancePolicy
        let managed: FakeManagedPolicy
        let window: NSWindow
    }

    private func makeRig(body: String = "Hello wrold {date}", optIn: Bool = true, reply: String = "") async throws -> Rig {
        let library = try await openTestLibrary()
        let snippet = try await seed(library, "Alpha", body: body)
        let editor = EditorViewModel(library: library, snippet: snippet)
        let scroll = RichTextView.makeScrollView(controller: editor.bodyController)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        let isolated = makeIsolatedDefaults()
        addTeardownBlock { UserDefaults(suiteName: isolated.name)?.removePersistentDomain(forName: isolated.name) }
        let managed = FakeManagedPolicy()
        let policy = WritingAssistancePolicy(defaults: isolated.defaults, managed: managed, availability: FakeAvailability(),
                                             locale: Locale(identifier: "en_US"))
        if optIn { policy.setAssistanceEnabled(true) }
        let factory = FakeModelFactory(.reply(reply))
        let service = AssistanceService.make(policy: policy, sessions: factory)
        let model = AssistanceEditorModel(editor: editor, service: service, policy: policy)
        return Rig(editor: editor, textView: scroll.documentView as! NSTextView, model: model, factory: factory, policy: policy,
                   managed: managed, window: window)
    }

    private func select(_ rig: Rig, _ text: String) throws {
        let range = (rig.textView.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        rig.textView.setSelectedRange(range)
    }

    // MARK: Availability

    func testTheActionIsNotOfferedWhileAssistanceIsOff() async throws {
        let rig = try await makeRig(optIn: false)
        try select(rig, "wrold")
        XCTAssertFalse(rig.model.isOffered)
        XCTAssertFalse(rig.model.canRequest)
        rig.policy.setAssistanceEnabled(true)
        XCTAssertTrue(rig.model.isOffered)
        XCTAssertTrue(rig.model.canRequest)
    }

    func testAManagedOffPolicyRemovesTheAction() async throws {
        let rig = try await makeRig()
        try select(rig, "wrold")
        rig.managed.value = .forbidden
        rig.policy.refresh()
        XCTAssertFalse(rig.model.isOffered)
        await rig.model.request(.proofread)
        XCTAssertEqual(rig.factory.created, 0, "No session when the policy forbids it")
    }

    func testWithoutASelectionThereIsNothingToRequest() async throws {
        let rig = try await makeRig()
        rig.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(rig.model.canRequest)
    }

    func testTypingSelectingAndEditingNeverCreateAModelSession() async throws {
        let rig = try await makeRig()
        try select(rig, "Hello")
        rig.editor.bodyController.insert(tokenSource: "{uuid}")
        rig.editor.bodyController.toggle(.bold)
        XCTAssertEqual(rig.factory.created, 0)
        XCTAssertEqual(rig.factory.responded, 0)
    }

    // MARK: Request, preview, apply

    func testProofreadPreviewsThenAppliesAsOneUndoableEditThatKeepsThePlaceholder() async throws {
        let rig = try await makeRig(reply: "world")
        try select(rig, "wrold")
        await rig.model.request(.proofread)
        guard case .proposed(let preview) = rig.model.state else { return XCTFail("state: \(rig.model.state)") }
        XCTAssertEqual(preview.originalText, "wrold")
        XCTAssertEqual(preview.proposedText, "world")
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello wrold {date}", "A preview changes nothing")
        XCTAssertFalse(rig.factory.prompts.contains { $0.contains("{date}") }, "token source never reaches the model")

        await rig.model.apply()
        XCTAssertEqual(rig.model.state, .idle)
        XCTAssertEqual(rig.textView.string, "Hello world {date}")
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello world {date}")
        XCTAssertTrue(rig.editor.draft.body.paragraphs.flatMap(\.runs).flatMap(\.spans).contains {
            if case .token(let token) = $0, token.kind == .date(format: nil) { true } else { false }
        }, "the date placeholder is still a token")
        XCTAssertEqual(rig.textView.selectedRange(), (rig.textView.string as NSString).range(of: "world"), "the replaced text stays selected")

        rig.textView.undoManager?.undo()
        XCTAssertEqual(rig.textView.string, "Hello wrold {date}", "one undo restores the original")
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello wrold {date}")
        rig.textView.undoManager?.redo()
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello world {date}", "and redo applies it again")
    }

    func testASuggestionThatDropsAPlaceholderIsRejectedAndNothingChanges() async throws {
        let rig = try await makeRig(body: "Fix teh {clipboard} please", reply: "Fix the please")
        try select(rig, "teh {clipboard} please")
        await rig.model.request(.proofread)
        guard case .failed(let message) = rig.model.state else { return XCTFail("state: \(rig.model.state)") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("placeholder"), message)
        XCTAssertEqual(rig.editor.draft.body.plainText, "Fix teh {clipboard} please")
        XCTAssertFalse(rig.factory.prompts.contains { $0.contains("clipboard") }, "clipboard is never resolved into a prompt")
    }

    func testCancelDiscardsTheSuggestionAndApplyCannotUseItLater() async throws {
        let rig = try await makeRig(reply: "world")
        try select(rig, "wrold")
        await rig.model.request(.proofread)
        rig.model.cancel()
        XCTAssertEqual(rig.model.state, .idle)
        await rig.model.apply()
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello wrold {date}")
    }

    func testSwitchingAssistanceOffWhileAProposalIsShownClearsIt() async throws {
        let rig = try await makeRig(reply: "world")
        try select(rig, "wrold")
        await rig.model.request(.proofread)
        rig.policy.setAssistanceEnabled(false)
        rig.model.policyChanged()
        XCTAssertEqual(rig.model.state, .idle)
        await rig.model.apply()
        XCTAssertEqual(rig.editor.draft.body.plainText, "Hello wrold {date}")
    }

    func testEditingAfterTheProposalMakesApplyStaleAndChangesNothingMore() async throws {
        let rig = try await makeRig(reply: "world")
        try select(rig, "wrold")
        await rig.model.request(.proofread)
        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
        rig.textView.insertText("Oh. ", replacementRange: NSRange(location: 0, length: 0))
        await rig.model.apply()
        guard case .failed = rig.model.state else { return XCTFail("state: \(rig.model.state)") }
        XCTAssertEqual(rig.editor.draft.body.plainText, "Oh. Hello wrold {date}")
    }

    func testAnUnchangedSuggestionOffersNoApply() async throws {
        let rig = try await makeRig(reply: "wrold")
        try select(rig, "wrold")
        await rig.model.request(.proofread)
        guard case .proposed(let preview) = rig.model.state else { return XCTFail("state: \(rig.model.state)") }
        XCTAssertEqual(preview.originalText, preview.proposedText)
        XCTAssertFalse(rig.model.canApply)
    }

    // MARK: Selection mapping

    func testASelectionInAListParagraphMapsToDocumentOffsetsWithoutTheMarker() async throws {
        let library = try await openTestLibrary()
        let document = Document(paragraphs: [
            Paragraph(kind: .bullet, runs: [Run(style: [], spans: [.literal("alpha")])]),
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("beta gamma")])]),
        ])
        let snippet = try await library.create(name: "List", icon: .emoji("x"), keyword: nil, template: document)
        let editor = EditorViewModel(library: library, snippet: snippet)
        let scroll = RichTextView.makeScrollView(controller: editor.bodyController)
        let textView = scroll.documentView as! NSTextView
        textView.setSelectedRange((textView.string as NSString).range(of: "gamma"))
        let selection = try XCTUnwrap(editor.bodyController.selectionInDocument())
        XCTAssertEqual(document.plainText, "alpha\nbeta gamma")
        XCTAssertEqual([selection.start, selection.end], [11, 16])
    }
}
