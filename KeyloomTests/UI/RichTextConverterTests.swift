import AppKit
import XCTest
@testable import Keyloom

final class RichTextConverterTests: XCTestCase {
    private func run(_ style: TextStyle = [], _ spans: TemplateSpan...) -> Run { Run(style: style, spans: spans) }
    private func para(_ kind: ParagraphKind = .plain, _ runs: Run...) -> Paragraph { Paragraph(kind: kind, runs: runs) }

    private func roundTrip(_ document: Document, file: StaticString = #filePath, line: UInt = #line) -> NSAttributedString {
        let text = RichTextConverter.attributedString(from: document)
        XCTAssertEqual(RichTextConverter.document(from: text), document, file: file, line: line)
        return text
    }

    func testPlainParagraphsRoundTrip() {
        let text = roundTrip(Document(paragraphs: [para(.plain, run([], .literal("One"))), para(.plain, run([], .literal("Two")))]))
        XCTAssertEqual(text.string, "One\nTwo")
    }

    func testEveryStyleCombinationRoundTrips() {
        let styles: [TextStyle] = [[], .bold, .italic, .underline, [.bold, .italic], [.bold, .underline], .all]
        let runs = styles.enumerated().map { Run(style: $1, spans: [.literal("s\($0)")]) }
        _ = roundTrip(Document(paragraphs: [Paragraph(kind: .plain, runs: runs)]))
    }

    func testBulletAndNumberedParagraphsShowMarkersAndRestartNumbering() {
        let document = Document(paragraphs: [
            para(.numbered, run([], .literal("a"))), para(.numbered, run([], .literal("b"))),
            para(.plain, run([], .literal("mid"))),
            para(.numbered, run([], .literal("c"))), para(.bullet, run([.bold], .literal("d")))])
        let text = roundTrip(document)
        XCTAssertEqual(text.string, "1. a\n2. b\nmid\n1. c\n• d")
    }

    func testStyledTokenSpanningUnicodeRoundTripsAndKeepsUTF16Offsets() throws {
        let raw = "{argument name=\"név\" default=\"日本語😀\"}"
        let token = try XCTUnwrap(try TokenParser.parse(raw).spans.compactMap { span -> Token? in
            if case .token(let token) = span.span { token } else { nil }
        }.first)
        let lead = "Grüße 👩‍👩‍👧 "
        let document = Document(paragraphs: [para(.plain, run([.bold, .italic], .literal(lead), .token(token), .literal(" 🎉 é")))])
        let text = roundTrip(document)

        var chip = NSRange(location: NSNotFound, length: 0)
        text.enumerateAttribute(RichTextConverter.tokenKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { chip = range }
        }
        XCTAssertEqual(chip, NSRange(location: lead.utf16.count, length: raw.utf16.count))
        XCTAssertEqual((text.string as NSString).substring(with: chip), raw)
    }

    func testUnsupportedTokenSurvivesRoundTrip() throws {
        let document = try TokenParser.parse("Hi {date offset=\"+1d\"} there").document
        _ = roundTrip(document)
    }

    func testPlainTextMatchesTheDocumentPlainText() throws {
        let document = try TokenParser.parse("Dear {argument name=\"who\" default=\"Ann\"},\n\nSee you {date format=\"yyyy\"}{cursor}").document
        XCTAssertEqual(RichTextConverter.attributedString(from: document).string, document.plainText)
    }

    func testParserDocumentsAndEmptyParagraphsRoundTrip() throws {
        _ = roundTrip(try TokenParser.parse("First\n\nThird").document)
        XCTAssertEqual(RichTextConverter.document(from: NSAttributedString(string: "")).paragraphs, [])
    }

    func testAdjacentSameStyleRunsMergeSoTheModelStaysCanonical() {
        let text = NSMutableAttributedString(attributedString: RichTextConverter.attributedString(
            from: Document(paragraphs: [para(.plain, run([], .literal("ab")))])))
        text.addAttribute(.toolTip, value: "x", range: NSRange(location: 1, length: 1))
        XCTAssertEqual(RichTextConverter.document(from: text).paragraphs, [para(.plain, run([], .literal("ab")))])
    }

    func testHandTypedTokenBecomesAChipOnRequestAndMalformedStaysText() {
        let text = NSMutableAttributedString(attributedString: RichTextConverter.attributedString(
            from: Document(paragraphs: [para(.plain, run([.bold], .literal("Hi {date format=\"yy\"} ok"))),
                                        para(.plain, run([], .literal("{date format=}")))])))
        RichTextConverter.chipTokens(in: text, paragraphAt: 0)
        RichTextConverter.chipTokens(in: text, paragraphAt: 1)
        let document = RichTextConverter.document(from: text)
        XCTAssertEqual(document.paragraphs[0].runs[0].style, .bold)
        let spans = document.paragraphs[0].runs[0].spans
        XCTAssertEqual(spans.count, 3)
        guard case .token(let token) = spans[1] else { return XCTFail("expected token") }
        XCTAssertEqual(token.kind, .date(format: "yy"))
        XCTAssertEqual(spans[2], .literal(" ok"))
        XCTAssertEqual(document.paragraphs[1].runs, [run([], .literal("{date format=}"))], "malformed source stays literal text")
    }

    func testAdjacentTokensOfOneStyleStayTokensNotLiteralText() throws {
        // Insert Placeholder twice in a row makes two chips with identical attributes; AppKit reports them as one run.
        let date = Token(kind: .date(format: nil), raw: "{date}")
        let argument = try XCTUnwrap(try TokenParser.parse("{argument name=\"recipient\" default=\"team\"}").spans.compactMap { span -> Token? in
            if case .token(let token) = span.span { token } else { nil }
        }.first)
        let document = Document(paragraphs: [para(.plain, run([], .literal("Hi "), .token(date), .token(argument)))])
        _ = roundTrip(document)
        XCTAssertEqual(TemplateRenderer.requiredArguments(in: RichTextConverter.document(from: RichTextConverter.attributedString(from: document))).map(\.name), ["recipient"])
    }

    func testTokenEditPolicyIsAtomic() {
        let text = RichTextConverter.attributedString(from: Document(paragraphs: [para(.plain, run([], .literal("ab"), .token(Token(kind: .uuid, raw: "{uuid}")), .literal("cd")))]))
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 4, length: 0), replacement: "x", in: text), .reject)
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 2, length: 0), replacement: "x", in: text), .allow)
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 8, length: 0), replacement: "x", in: text), .allow)
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 4, length: 1), replacement: "", in: text), .replace(NSRange(location: 2, length: 6)))
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 1, length: 3), replacement: "", in: text), .replace(NSRange(location: 1, length: 7)))
        XCTAssertEqual(RichTextConverter.tokenEdit(range: NSRange(location: 0, length: 2), replacement: "", in: text), .allow)
    }
}
