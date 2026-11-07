import AppKit
import XCTest
@testable import Keyloom

@MainActor
final class RichTextControllerTests: XCTestCase {
    private func run(_ style: TextStyle = [], _ spans: TemplateSpan...) -> Run { Run(style: style, spans: spans) }
    private func para(_ kind: ParagraphKind = .plain, _ runs: Run...) -> Paragraph { Paragraph(kind: kind, runs: runs) }

    @MainActor private struct Harness {
        let controller: RichTextController
        let textView: NSTextView
        let emitted: Emitted
        var document: Document { RichTextConverter.document(from: textView.attributedString()) }
    }

    @MainActor final class Emitted { var documents: [Document] = [] }

    private func harness(_ document: Document) -> Harness {
        let controller = RichTextController()
        let scroll = RichTextView.makeScrollView(controller: controller)
        let textView = scroll.documentView as! NSTextView
        let emitted = Emitted()
        controller.onChange = { emitted.documents.append($0) }
        controller.load(document)
        return Harness(controller: controller, textView: textView, emitted: emitted)
    }

    private func plain(_ text: String) -> Document { Document(paragraphs: [para(.plain, run([], .literal(text)))]) }

    func testWritingToolsAreDisabledAndSmartSubstitutionsAreOff() {
        let textView = harness(plain("x")).textView
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled, "straight quotes keep token attributes valid")
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertEqual(textView.accessibilityLabel(), "Snippet body")
    }

    func testLoadingDoesNotEmitAChangeButEditingDoes() {
        let h = harness(plain("Hello"))
        XCTAssertTrue(h.emitted.documents.isEmpty)
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        h.textView.insertText("!", replacementRange: h.textView.selectedRange())
        XCTAssertEqual(h.emitted.documents.last, plain("Hello!"))
    }

    func testToggleBoldOnASelectionAndBackOff() {
        let h = harness(plain("Hello world"))
        h.textView.setSelectedRange(NSRange(location: 6, length: 5))
        h.controller.toggle(.bold)
        XCTAssertEqual(h.document.paragraphs[0].runs, [run([], .literal("Hello ")), run(.bold, .literal("world"))])
        XCTAssertEqual(h.controller.activeStyles, .bold)
        h.controller.toggle(.bold)
        XCTAssertEqual(h.document, plain("Hello world"))
        XCTAssertEqual(h.emitted.documents.last, plain("Hello world"))
    }

    func testToggleWithACaretStylesTheNextTypedText() {
        let h = harness(plain("ab"))
        h.textView.setSelectedRange(NSRange(location: 2, length: 0))
        h.controller.toggle(.italic)
        h.controller.toggle(.underline)
        h.textView.insertText("cd", replacementRange: h.textView.selectedRange())
        XCTAssertEqual(h.document.paragraphs[0].runs, [run([], .literal("ab")), run([.italic, .underline], .literal("cd"))])
    }

    func testSetParagraphKindTogglesBulletNumberedAndPlain() {
        let h = harness(Document(paragraphs: [para(.plain, run([], .literal("a"))), para(.plain, run([], .literal("b")))]))
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        h.controller.setKind(.numbered)
        XCTAssertEqual(h.textView.string, "1. a\n2. b")
        XCTAssertEqual(h.document.paragraphs.map(\.kind), [.numbered, .numbered])
        h.textView.setSelectedRange(NSRange(location: 6, length: 0))
        h.controller.setKind(.bullet)
        XCTAssertEqual(h.textView.string, "1. a\n• b")
        XCTAssertEqual(h.controller.activeKind, .bullet)
        h.controller.setKind(.bullet)
        XCTAssertEqual(h.textView.string, "1. a\nb", "choosing the active kind again clears it")
        XCTAssertEqual(h.document.paragraphs.map(\.kind), [.numbered, .plain])
        XCTAssertEqual(h.document.paragraphs[1].runs, [run([], .literal("b"))])
    }

    func testReturnContinuesAListAndAnEmptyItemEndsIt() {
        let h = harness(Document(paragraphs: [para(.numbered, run([], .literal("a")))]))
        h.textView.setSelectedRange(NSRange(location: 4, length: 0))
        h.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.textView.string, "1. a\n2. ")
        h.textView.insertText("b", replacementRange: h.textView.selectedRange())
        XCTAssertEqual(h.document.paragraphs.map(\.kind), [.numbered, .numbered])
        h.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        h.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(h.textView.string, "1. a\n2. b\n")
        XCTAssertEqual(h.document.paragraphs.map(\.kind), [.numbered, .numbered, .plain])
    }

    func testBackspaceRightAfterTheMarkerRemovesTheListFormatting() {
        let h = harness(Document(paragraphs: [para(.bullet, run([], .literal("item")))]))
        h.textView.setSelectedRange(NSRange(location: 2, length: 0))
        h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.textView.string, "item")
        XCTAssertEqual(h.document, Document(paragraphs: [para(.plain, run([], .literal("item")))]))
    }

    func testInsertedTokenInheritsStyleAndIsAtomic() {
        let h = harness(Document(paragraphs: [para(.plain, run(.bold, .literal("Hi ")))]))
        h.textView.setSelectedRange(NSRange(location: 3, length: 0))
        h.controller.insert(tokenSource: "{uuid}")
        XCTAssertEqual(h.document.paragraphs[0].runs, [run(.bold, .literal("Hi "), .token(Token(kind: .uuid, raw: "{uuid}")))])

        h.textView.insertText("x", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(h.textView.string, "Hi {uuid}", "typing inside a token is refused")
        h.textView.insertText("!", replacementRange: NSRange(location: 9, length: 0))
        XCTAssertEqual(h.document.paragraphs[0].runs.last?.spans.last, .literal("!"), "text after a chip is not part of it")

        h.textView.insertText("", replacementRange: NSRange(location: 6, length: 1))
        XCTAssertEqual(h.textView.string, "Hi !", "deleting part of a token deletes all of it")
    }

    func testPastingRaycastSyntaxBecomesAToken() {
        let h = harness(plain("Date: "))
        h.textView.insertText("{date format=\"yyyy-MM-dd\"}", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(h.document.paragraphs[0].runs[0].spans.last, .token(Token(kind: .date(format: "yyyy-MM-dd"), raw: "{date format=\"yyyy-MM-dd\"}")))
    }

    func testCursorTokenAvailabilityFollowsTheDocument() {
        let h = harness(plain("x"))
        XCTAssertFalse(h.controller.hasCursorToken)
        h.controller.insert(tokenSource: "{cursor}")
        XCTAssertTrue(h.controller.hasCursorToken)
    }

    func testSelectionSnapsOutOfTokensAndMarkers() {
        let h = harness(Document(paragraphs: [para(.bullet, run([], .literal("a"), .token(Token(kind: .uuid, raw: "{uuid}")), .literal("b")))]))
        // "• a{uuid}b": marker 0..<2, token 3..<9
        let controller = h.controller
        XCTAssertEqual(controller.adjustedSelection(from: NSRange(location: 3, length: 0), to: NSRange(location: 5, length: 0)), NSRange(location: 9, length: 0))
        XCTAssertEqual(controller.adjustedSelection(from: NSRange(location: 9, length: 0), to: NSRange(location: 5, length: 0)), NSRange(location: 3, length: 0))
        XCTAssertEqual(controller.adjustedSelection(from: NSRange(location: 3, length: 0), to: NSRange(location: 1, length: 0)), NSRange(location: 2, length: 0))
        XCTAssertEqual(controller.adjustedSelection(from: NSRange(location: 2, length: 0), to: NSRange(location: 2, length: 4)), NSRange(location: 2, length: 7))
    }
}
