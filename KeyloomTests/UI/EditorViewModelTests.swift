import XCTest
@testable import Keyloom

@MainActor
final class EditorViewModelTests: LibraryUITestCase {
    private func makeEditor(_ library: SnippetLibrary, snippet: Snippet? = nil) -> EditorViewModel {
        EditorViewModel(library: library, snippet: snippet, environment: { [clock] in
            RenderEnvironment(date: clock.now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"),
                              makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")! }, clipboardText: { "sample clipboard" })
        })
    }

    func testNewDraftIsCleanUntilEditedAndNeedsAName() async throws {
        let editor = makeEditor(try await openLibrary())
        XCTAssertFalse(editor.isDirty)
        XCTAssertFalse(editor.canSave)
        editor.draft.name = "Greeting"
        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.canSave)
        editor.draft.name = "   "
        XCTAssertFalse(editor.canSave, "a blank name cannot be saved")
    }

    func testSaveCreatesTheSnippetWithParsedTagsAndOptionalKeyword() async throws {
        let library = try await openLibrary()
        let editor = makeEditor(library)
        editor.draft.name = "Greeting"
        editor.draft.icon = .emoji("👋")
        editor.draft.keyword = "  "
        editor.draft.tagsText = "work, mail ,, work"
        editor.draft.body = try document("Hello {cursor}")
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let all = await library.allSnippets()
        let stored = try XCTUnwrap(all.first)
        XCTAssertEqual(stored.name, "Greeting")
        XCTAssertEqual(stored.icon, .emoji("👋"))
        XCTAssertNil(stored.keyword)
        XCTAssertEqual(stored.tags, ["work", "mail"])
        XCTAssertEqual(stored.template, try document("Hello {cursor}"))
        XCTAssertEqual(editor.target, .existing(stored.id))
        XCTAssertFalse(editor.isDirty)
    }

    func testEditingAnExistingSnippetKeepsItsIDAndOtherFields() async throws {
        let library = try await openLibrary()
        let original = try await seed(library, "Old", keyword: ";old")
        let editor = makeEditor(library, snippet: original)
        _ = try await library.setPinned(true, id: original.id)
        editor.draft.name = "New"
        editor.draft.icon = .symbol("star")
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let stored = await library.snippet(id: original.id)
        XCTAssertEqual(stored?.name, "New")
        XCTAssertEqual(stored?.icon, .symbol("star"))
        XCTAssertEqual(stored?.keyword, ";old")
        XCTAssertEqual(stored?.pinned, true, "a pin set elsewhere is not overwritten")
        XCTAssertGreaterThan(stored?.revision ?? 0, original.revision)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 1)
    }

    func testSaveRefusesABlankNameAndAnInvalidDocumentWithoutStoringAnything() async throws {
        let library = try await openLibrary()
        let editor = makeEditor(library)
        editor.draft.name = ""
        let blank = await editor.save()
        XCTAssertFalse(blank)
        editor.draft.name = "Two cursors"
        editor.draft.body = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [
            .token(Token(kind: .cursor, raw: "{cursor}")), .token(Token(kind: .cursor, raw: "{cursor}"))])])])
        let invalid = await editor.save()
        XCTAssertFalse(invalid)
        XCTAssertEqual(editor.errorMessage, "A snippet can have only one cursor placeholder.")
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(editor.isDirty, "a failed save keeps the edits")
    }

    func testChangingOnlyTheSymbolColorMakesTheDraftDirtyAndSavesARevision() async throws {
        let library = try await openLibrary()
        var original = try await seed(library, "Tinted")
        original.icon = .symbol("star")
        original = try await library.update(original)
        let editor = makeEditor(library, snippet: original)
        XCTAssertFalse(editor.isDirty)
        editor.draft.icon = .symbol("star", color: .green)
        XCTAssertTrue(editor.isDirty, "a color-only change is an edit")
        XCTAssertTrue(editor.canSave)
        let saved = await editor.save()
        XCTAssertTrue(saved)
        let stored = await library.snippet(id: original.id)
        XCTAssertEqual(stored?.icon, .symbol("star", color: .green))
        XCTAssertEqual(stored?.revision, original.revision + 1)
        XCTAssertFalse(editor.isDirty)
    }

    func testRevertRestoresTheSavedDraftAndBody() async throws {
        let library = try await openLibrary()
        let original = try await seed(library, "Name", body: "Saved text")
        let editor = makeEditor(library, snippet: original)
        editor.draft.name = "Changed"
        editor.draft.body = try document("Changed text")
        XCTAssertTrue(editor.isDirty)
        editor.revert()
        XCTAssertEqual(editor.draft.name, "Name")
        XCTAssertEqual(editor.draft.body, try document("Saved text"))
        XCTAssertFalse(editor.isDirty)
    }

    func testBodyEditsFlowFromTheTextControlIntoTheDraftWithoutTouchingTheLibrary() async throws {
        let library = try await openLibrary()
        let editor = makeEditor(library)
        let scroll = RichTextView.makeScrollView(controller: editor.bodyController)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        textView.insertText("Typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.draft.body.plainText, "Typed")
        XCTAssertTrue(editor.isDirty)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 0, "typing alone writes nothing")
    }

    func testLivePreviewRendersTemplateWithSampleValues() async throws {
        let editor = makeEditor(try await openLibrary())
        editor.draft.body = try document("Hi {argument name=\"who\" default=\"Ann\"} {uuid} {clipboard}")
        guard case .rendered(let rendered) = editor.preview else { return XCTFail("expected a preview") }
        XCTAssertEqual(rendered.plainText, "Hi Ann 00000000-0000-0000-0000-00000000ABCD sample clipboard")
    }

    func testPreviewReportsAnUnrenderableTemplateInsteadOfFailing() async throws {
        let editor = makeEditor(try await openLibrary())
        editor.draft.body = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [
            .token(Token(kind: .argument(name: "x", defaultValue: "z", choices: ["a", "b"]), raw: "{argument}"))])])])
        guard case .unavailable(let message) = editor.preview else { return XCTFail("expected unavailable") }
        XCTAssertFalse(message.isEmpty)
    }

    func testKeywordHintSuggestsTheDoubleColonPrefixButAcceptsAnything() async throws {
        let editor = makeEditor(try await openLibrary())
        XCTAssertNil(editor.keywordHint, "empty keyword: no hint, the placeholder suggests ::")
        editor.draft.keyword = ";sig"
        XCTAssertNotNil(editor.keywordHint)
        editor.draft.keyword = "::sig"
        XCTAssertNil(editor.keywordHint)
        editor.draft.name = "X"
        editor.draft.keyword = ";sig"
        XCTAssertTrue(editor.canSave, "any keyword is accepted")
    }

    func testBackToBackPlaceholdersRenderInThePreviewOfferTheArgumentAndSurviveSaveAndReselect() async throws {
        let library = try await openLibrary()
        let editor = makeEditor(library)
        _ = RichTextView.makeScrollView(controller: editor.bodyController)
        editor.bodyController.insert(tokenSource: try Placeholder.date(format: nil).source())
        editor.bodyController.insert(tokenSource: try Placeholder.argument(name: "recipient", defaultValue: "team", choices: []).source())
        func assertRendered(_ editor: EditorViewModel, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(editor.argumentRequirements.map(\.name), ["recipient"], "Try Expansion offers the argument \(context)", file: file, line: line)
            guard case .rendered(let rendered) = editor.preview else { return XCTFail("expected a preview \(context)", file: file, line: line) }
            XCTAssertFalse(rendered.plainText.contains("{"), "tokens are substituted \(context), got \(rendered.plainText)", file: file, line: line)
            XCTAssertTrue(rendered.plainText.hasSuffix("team"), "the argument shows its default \(context), got \(rendered.plainText)", file: file, line: line)
        }
        assertRendered(editor, "before saving")
        editor.sampleArguments["recipient"] = "Ana"
        guard case .rendered(let typed) = editor.preview else { return XCTFail("expected a preview") }
        XCTAssertTrue(typed.plainText.hasSuffix("Ana"), "a typed sample replaces the default")
        editor.sampleArguments = [:]

        editor.draft.name = "Greeting"
        let saved = await editor.save()
        XCTAssertTrue(saved)
        assertRendered(editor, "after saving")
        let all = await library.allSnippets()
        let stored = try XCTUnwrap(all.first)
        assertRendered(makeEditor(library, snippet: stored), "after reselecting")
    }
}
