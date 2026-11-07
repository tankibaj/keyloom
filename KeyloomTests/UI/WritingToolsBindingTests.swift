import AppKit
import XCTest
@testable import Keyloom

@MainActor
final class WritingToolsBindingTests: LibraryUITestCase {
    private func policy(managed: ManagedAssistancePolicy = .notManaged) -> (WritingAssistancePolicy, FakeManagedPolicy) {
        let isolated = makeIsolatedDefaults()
        addTeardownBlock { UserDefaults(suiteName: isolated.name)?.removePersistentDomain(forName: isolated.name) }
        let reader = FakeManagedPolicy(managed)
        return (WritingAssistancePolicy(defaults: isolated.defaults, managed: reader, availability: FakeAvailability()), reader)
    }

    private func textView(of controller: RichTextController) -> NSTextView {
        RichTextView.makeScrollView(controller: controller).documentView as! NSTextView
    }

    func testControllerStartsWithWritingToolsOffAndMapsBothBehaviors() {
        let controller = RichTextController()
        let view = textView(of: controller)
        XCTAssertEqual(view.writingToolsBehavior, NSWritingToolsBehavior.none)
        controller.writingToolsBehavior = .default
        XCTAssertEqual(view.writingToolsBehavior, .default)
        controller.writingToolsBehavior = .none
        XCTAssertEqual(view.writingToolsBehavior, NSWritingToolsBehavior.none)
    }

    func testABehaviorSetBeforeTheViewExistsIsAppliedWhenItAttaches() {
        let controller = RichTextController()
        controller.writingToolsBehavior = .default
        XCTAssertEqual(textView(of: controller).writingToolsBehavior, .default)
    }

    func testAnOpenedEditorFollowsThePolicyAndAChangeReachesTheOpenEditor() async throws {
        let (policy, _) = policy()
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] in try await openLibrary(at: $0) })
        model.bindWritingTools(to: policy)
        await model.open()
        await model.requestNewSnippet()
        let editor = try XCTUnwrap(model.editor)
        XCTAssertEqual(editor.bodyController.writingToolsBehavior, EditorWritingToolsBehavior.none, "Both opt-ins are off by default")

        policy.setSystemWritingToolsEnabled(true)
        XCTAssertEqual(editor.bodyController.writingToolsBehavior, .default)

        await model.requestNewSnippet()
        XCTAssertEqual(model.editor?.bodyController.writingToolsBehavior, .default, "A later editor starts from the current policy")

        policy.setSystemWritingToolsEnabled(false)
        XCTAssertEqual(model.editor?.bodyController.writingToolsBehavior, EditorWritingToolsBehavior.none)
    }

    func testAManagedOffPolicyOverridesTheUsersOptIn() async throws {
        let (policy, managed) = policy()
        policy.setSystemWritingToolsEnabled(true)
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] in try await openLibrary(at: $0) })
        model.bindWritingTools(to: policy)
        await model.open()
        await model.requestNewSnippet()
        XCTAssertEqual(model.editor?.bodyController.writingToolsBehavior, .default)
        managed.value = .forbidden
        policy.refresh()
        XCTAssertEqual(model.editor?.bodyController.writingToolsBehavior, EditorWritingToolsBehavior.none)
    }
}
