import XCTest
@testable import Keyloom

final class EditPlannerTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!

    private func document(_ source: String) throws -> Document { try TokenParser.parse(source).document }

    /// UTF-16 range of the first occurrence of `text` in the document's plain text.
    private func select(_ text: String, in document: Document) throws -> ValidatedUTF16Range {
        let plain = document.plainText
        let range = try XCTUnwrap(plain.range(of: text), "fixture text not found")
        return try ValidatedUTF16Range(range, in: plain)
    }

    private func request(_ source: String, select text: String, action: EditAction = .proofread, revision: Int = 7) throws -> EditRequest {
        let doc = try document(source)
        return EditRequest(action: action, document: doc, revision: revision, selection: try select(text, in: doc))
    }

    private func propose(_ request: EditRequest, reply: String) throws -> ProposedEdit {
        try EditPlanner.plan(request).proposal(from: reply, id: id)
    }

    private func assertRejected(_ reason: RejectionReason, _ request: EditRequest, reply: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try propose(request, reply: reply), file: file, line: line) {
            XCTAssertEqual($0 as? AssistanceError, .rejectedSuggestion(reason), file: file, line: line)
        }
    }

    private func assertSelectionError(_ expected: AssistanceError, _ build: () throws -> EditRequest,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EditPlanner.plan(build()), file: file, line: line) {
            XCTAssertEqual($0 as? AssistanceError, expected, file: file, line: line)
        }
    }

    private func tokens(_ document: Document) -> [Token] {
        document.paragraphs.flatMap(\.runs).flatMap(\.spans).compactMap {
            if case .token(let token) = $0 { token } else { nil }
        }
    }

    // MARK: Prompt

    func testPromptMasksEveryTokenAndNeverCarriesTokenSource() throws {
        let req = try request(#"Dear {argument name="who" default="Sam"}, fix {clipboard} and {date} now."#,
                              select: #"Dear {argument name="who" default="Sam"}, fix {clipboard} and {date} now."#)
        let plan = try EditPlanner.plan(req)
        XCTAssertEqual(plan.prompt, "Dear ⟦1⟧, fix ⟦2⟧ and ⟦3⟧ now.")
        for leaked in ["clipboard", "argument", "who", "Sam", "{date}"] {
            XCTAssertFalse(plan.prompt.contains(leaked))
            XCTAssertFalse(plan.instructions.contains(leaked))
        }
    }

    func testPromptHoldsOnlyTheSelectedProse() throws {
        let req = try request("First paragraph SECRET.\nPls fix teh {clipboard} text.\nThird SECRET.", select: "fix teh {clipboard} text")
        let plan = try EditPlanner.plan(req)
        XCTAssertEqual(plan.prompt, "fix teh ⟦1⟧ text")
        XCTAssertFalse(plan.prompt.contains("SECRET"))
        XCTAssertFalse(plan.instructions.contains("SECRET"))
    }

    func testEachActionHasItsOwnFixedInstructions() throws {
        let doc = try document("some prose here")
        let selection = try select("some prose here", in: doc)
        let all: [EditAction] = [.proofread, .shorten, .changeTone(.professional), .changeTone(.friendly), .changeTone(.casual)]
        let instructions = try all.map { try EditPlanner.plan(EditRequest(action: $0, document: doc, revision: 1, selection: selection)).instructions }
        XCTAssertEqual(Set(instructions).count, all.count)
        for text in instructions { XCTAssertTrue(text.contains("⟦1⟧") || text.contains("placeholder")) }
    }

    // MARK: Splice and formatting

    func testReplacementKeepsFormattingOutsideTheSelection() throws {
        let boldRun = Run(style: .bold, spans: [.literal("Heading. ")])
        let middle = Run(style: [], spans: [.literal("teh quick "), .token(Token(kind: .clipboard, raw: "{clipboard}")), .literal(" fox")])
        let italicRun = Run(style: .italic, spans: [.literal(" tail")])
        let doc = Document(paragraphs: [Paragraph(kind: .bullet, runs: [boldRun, middle, italicRun])])
        let req = EditRequest(action: .proofread, document: doc, revision: 3,
                              selection: try select("teh quick {clipboard} fox", in: doc))
        let edit = try propose(req, reply: "the quick ⟦1⟧ fox")
        let result = edit.applyPayload.document
        XCTAssertEqual(result.paragraphs.count, 1)
        XCTAssertEqual(result.paragraphs[0].kind, .bullet)
        XCTAssertEqual(result.paragraphs[0].runs.first, boldRun)
        XCTAssertEqual(result.paragraphs[0].runs.last, italicRun)
        XCTAssertEqual(result.plainText, "Heading. the quick {clipboard} fox tail")
        XCTAssertNoThrow(try result.validate())
    }

    func testOtherParagraphsAreUntouched() throws {
        let doc = try document("Keep me.\nfix teh word\nKeep me too.")
        let req = EditRequest(action: .proofread, document: doc, revision: 1, selection: try select("teh", in: doc))
        let result = try propose(req, reply: "the").applyPayload.document
        XCTAssertEqual(result.paragraphs[0], doc.paragraphs[0])
        XCTAssertEqual(result.paragraphs[2], doc.paragraphs[2])
        XCTAssertEqual(result.plainText, "Keep me.\nfix the word\nKeep me too.")
    }

    func testSelectionInsideOneRunSplitsItKeepingTheStyle() throws {
        let doc = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: .bold, spans: [.literal("aaa bbb ccc")])])])
        let req = EditRequest(action: .shorten, document: doc, revision: 1, selection: try select("bbb", in: doc))
        let result = try propose(req, reply: "B").applyPayload.document
        XCTAssertEqual(result.paragraphs[0].runs, [Run(style: .bold, spans: [.literal("aaa "), .literal("B"), .literal(" ccc")])])
    }

    func testTokensKeepTheirOwnRunStyleAndProseTakesTheFirstProseStyle() throws {
        let token = Token(kind: .uuid, raw: "{uuid}")
        let doc = Document(paragraphs: [Paragraph(kind: .plain, runs: [
            Run(style: .bold, spans: [.literal("id "), .token(token)]),
            Run(style: [], spans: [.literal(" is teh key")]),
        ])])
        let req = EditRequest(action: .proofread, document: doc, revision: 1, selection: try select("id {uuid} is teh key", in: doc))
        let result = try propose(req, reply: "ID ⟦1⟧ is the key").applyPayload.document
        XCTAssertEqual(result.paragraphs[0].runs, [
            Run(style: .bold, spans: [.literal("ID "), .token(token), .literal(" is the key")]),
        ])
    }

    func testSelectionWhitespaceIsPreserved() throws {
        let doc = try document("a  teh  b")
        let req = EditRequest(action: .proofread, document: doc, revision: 1, selection: try select("  teh  ", in: doc))
        XCTAssertEqual(try propose(req, reply: "the").applyPayload.document.plainText, "a  the  b")
    }

    func testOffsetsAreUTF16AcrossEmojiAndCombiningMarks() throws {
        let doc = try document("héllo 👩‍💻 wrld {uuid} 😀 end")
        let req = EditRequest(action: .proofread, document: doc, revision: 1, selection: try select("wrld {uuid} 😀", in: doc))
        let edit = try propose(req, reply: "world ⟦1⟧ 😀")
        XCTAssertEqual(edit.applyPayload.document.plainText, "héllo 👩‍💻 world {uuid} 😀 end")
        let plain = edit.applyPayload.document.plainText
        let range = try edit.applyPayload.selection.stringRange(in: plain)
        XCTAssertEqual(String(plain[range]), "world {uuid} 😀")
    }

    // MARK: Token immutability

    func testTokensSurviveInOrderAndByteEqual() throws {
        let source = #"Hi {argument name="n" default="x" options="x, y"} {date format="yyyy"} {cursor}"#
        let req = try request(source, select: source)
        let edit = try propose(req, reply: "Hello ⟦1⟧ ⟦2⟧ ⟦3⟧")
        XCTAssertEqual(tokens(edit.applyPayload.document), tokens(req.document))
    }

    func testRejectsDroppedDuplicatedReorderedAndUnknownPlaceholders() throws {
        let req = try request("a {uuid} b {clipboard} c", select: "a {uuid} b {clipboard} c")
        assertRejected(.tokenDropped, req, reply: "a ⟦1⟧ b c")
        assertRejected(.tokenDropped, req, reply: "a b c")
        assertRejected(.tokenDuplicated, req, reply: "a ⟦1⟧ ⟦1⟧ b ⟦2⟧ c")
        assertRejected(.tokenReordered, req, reply: "a ⟦2⟧ b ⟦1⟧ c")
        assertRejected(.malformedPlaceholder, req, reply: "a ⟦1⟧ b ⟦2⟧ ⟦9⟧ c")
        assertRejected(.malformedPlaceholder, req, reply: "a ⟦1⟧ b ⟦2⟧ ⟦x⟧ c")
        assertRejected(.malformedPlaceholder, req, reply: "a ⟦1⟧ b ⟦2⟧ ⟦3 c")
        assertRejected(.malformedPlaceholder, req, reply: "a ⟦1⟧ b ⟦2⟧ c ⟧")
    }

    func testRejectsTokenSyntaxTheModelInvented() throws {
        let req = try request("hello there", select: "hello there")
        assertRejected(.tokenSyntaxIntroduced, req, reply: "hello {clipboard}")
        assertRejected(.tokenSyntaxIntroduced, req, reply: "hello {")
    }

    func testABraceAlreadyInTheSelectedProseIsNotNewSyntax() throws {
        let doc = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("use { carefully")])])])
        let req = EditRequest(action: .proofread, document: doc, revision: 1, selection: try select("use { carefully", in: doc))
        XCTAssertEqual(try propose(req, reply: "Use { carefully").applyPayload.document.plainText, "Use { carefully")
    }

    func testRejectsEmptyAndMultiParagraphReplies() throws {
        let req = try request("hello there", select: "hello there")
        assertRejected(.emptyResult, req, reply: "")
        assertRejected(.emptyResult, req, reply: " \n ")
        assertRejected(.multiParagraphResult, req, reply: "hello\nthere")
    }

    func testRejectsAResultThatBreaksDocumentLimits() throws {
        let req = try request("hello there", select: "hello there")
        assertRejected(.invalidDocument, req, reply: String(repeating: "x", count: DocumentLimits.maxTextBytes + 1))
    }

    // MARK: Selection checks

    func testSelectionMustBeNonEmptyProseInOneParagraph() throws {
        let doc = try document("one two\nthree {clipboard}")
        let plain = doc.plainText
        assertSelectionError(.emptySelection) {
            EditRequest(action: .proofread, document: doc, revision: 1, selection: try ValidatedUTF16Range(start: 2, end: 2, in: plain))
        }
        assertSelectionError(.selectionSpansParagraphs) {
            EditRequest(action: .proofread, document: doc, revision: 1, selection: try ValidatedUTF16Range(start: 4, end: 10, in: plain))
        }
        assertSelectionError(.selectionNotProse) {
            try self.request("one {clipboard} two", select: "{clipboard}")
        }
        assertSelectionError(.selectionNotProse) {
            try self.request("one   two", select: "   ")
        }
    }

    func testPartiallySelectedTokenIsRejected() throws {
        assertSelectionError(.selectionSplitsToken) { try self.request("a {clipboard} b", select: "a {clip") }
        assertSelectionError(.selectionSplitsToken) { try self.request("a {clipboard} b", select: "board} b") }
        assertSelectionError(.selectionSplitsToken) { try self.request("a {clipboard} b", select: "ipboa") }
    }

    func testRangeOutsideTheDocumentIsATypedError() throws {
        let doc = try document("short")
        let longer = try ValidatedUTF16Range(start: 0, end: 20, in: String(repeating: "x", count: 30))
        XCTAssertThrowsError(try EditPlanner.plan(EditRequest(action: .proofread, document: doc, revision: 1, selection: longer))) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: 20, length: 5))
        }
    }

    func testOversizeAndReservedMarkerSelectionsAreRejectedBeforeAnyPrompt() throws {
        let big = String(repeating: "word ", count: EditPlanner.maxSelectionBytes / 5 + 1)
        assertSelectionError(.selectionTooLarge(maximum: EditPlanner.maxSelectionBytes)) { try self.request(big, select: big) }
        assertSelectionError(.selectionContainsReservedMarkers) { try self.request("a ⟦1⟧ b", select: "a ⟦1⟧ b") }
    }

    // MARK: Proposal payloads

    func testPreviewAndPayloadsCarryApplyCancelUndoData() throws {
        let req = try request("Pls fix teh {clipboard} now", select: "fix teh {clipboard}", revision: 12)
        let edit = try propose(req, reply: "fix the ⟦1⟧")
        XCTAssertEqual(edit.id, id)
        XCTAssertEqual(edit.baseRevision, 12)
        XCTAssertEqual(edit.preview.originalText, "fix teh {clipboard}")
        XCTAssertEqual(edit.preview.proposedText, "fix the {clipboard}")
        XCTAssertTrue(edit.preview.hasChanges)
        XCTAssertEqual(edit.applyPayload.document.plainText, "Pls fix the {clipboard} now")
        XCTAssertEqual(edit.applyPayload.baseRevision, 12)
        XCTAssertEqual(edit.applyPayload.undo.document, req.document)
        XCTAssertEqual(edit.applyPayload.undo.selection, req.selection)
        XCTAssertEqual(edit.originalSelection, req.selection)
        let plain = edit.applyPayload.document.plainText
        XCTAssertEqual(String(plain[try edit.applyPayload.selection.stringRange(in: plain)]), "fix the {clipboard}")
        XCTAssertEqual(edit.applyPayload.selection.start, req.selection.start)
    }

    func testAnUnchangedReplyIsFlaggedAsNoChange() throws {
        let req = try request("all good here", select: "all good here")
        let edit = try propose(req, reply: "all good here")
        XCTAssertFalse(edit.preview.hasChanges)
        XCTAssertEqual(edit.applyPayload.document, req.document)
    }

    // MARK: Redaction

    func testDescriptionsNeverExposeTextOrTokens() throws {
        let req = try request("My secret {clipboard} text", select: "My secret {clipboard} text")
        let plan = try EditPlanner.plan(req)
        let edit = try propose(req, reply: "My secret ⟦1⟧ texts")
        for object in [String(describing: req), String(describing: plan), String(describing: edit),
                       String(reflecting: req), String(describing: AssistanceError.rejectedSuggestion(.tokenDropped))] {
            XCTAssertFalse(object.contains("secret"))
            XCTAssertFalse(object.contains("clipboard"))
        }
    }
}
