import XCTest
@testable import Keyloom

final class DocumentTests: XCTestCase {
    /// Follow-up template: argument, date, two paragraphs, a list item and one cursor.
    private func sampleDocument() -> Document {
        Document(paragraphs: [
            Paragraph(kind: .plain, runs: [
                Run(style: [], spans: [.literal("Hi "), .token(Token(kind: .argument(name: "recipient", defaultValue: "team", choices: ["team", "Sam"]), raw: "{argument name=\"recipient\" default=\"team\"}"))]),
                Run(style: [.bold, .italic], spans: [.literal(", on "), .token(Token(kind: .date(format: "yyyy-MM-dd"), raw: "{date format=\"yyyy-MM-dd\"}"))]),
            ]),
            Paragraph(kind: .bullet, runs: [Run(style: .underline, spans: [.token(Token(kind: .clipboard, raw: "{clipboard}"))])]),
            Paragraph(kind: .numbered, runs: [Run(style: [], spans: [.token(Token(kind: .uuid, raw: "{uuid}")), .token(Token(kind: .time(format: nil), raw: "{time}")), .token(Token(kind: .unsupported(raw: "{foo bar}"), raw: "{foo bar}"))])]),
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("Thanks"), .token(Token(kind: .cursor, raw: "{cursor}"))])]),
        ])
    }

    private func decodeError(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> KeyloomError? {
        do {
            _ = try Document.decode(from: data)
            XCTFail("expected decode to fail", file: file, line: line)
            return nil
        } catch {
            return error as? KeyloomError
        }
    }

    func testRoundTripPreservesEverythingAndWritesSchemaVersion() throws {
        let document = sampleDocument()
        let data = try document.encoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\":1"), json)
        XCTAssertEqual(document.schemaVersion, Document.currentSchemaVersion)
        XCTAssertEqual(try Document.decode(from: data), document)
    }

    func testRoundTripKeepsRawSourceOfUnsupportedToken() throws {
        let decoded = try Document.decode(from: try sampleDocument().encoded())
        let tokens = decoded.paragraphs.flatMap(\.runs).flatMap(\.spans).compactMap { span -> Token? in
            if case .token(let token) = span { return token }
            return nil
        }
        XCTAssertEqual(tokens.last { if case .unsupported = $0.kind { return true } else { return false } }?.raw, "{foo bar}")
    }

    func testRejectsFutureSchemaVersion() {
        let data = Data(#"{"schemaVersion":2,"paragraphs":[]}"#.utf8)
        XCTAssertEqual(decodeError(data), .unsupportedSchemaVersion(found: 2, supported: 1))
    }

    func testRejectsMalformedJSONAndMissingFields() {
        guard case .malformedDocument = decodeError(Data("not json".utf8)) else { return XCTFail("garbage") }
        guard case .malformedDocument = decodeError(Data(#"{"schemaVersion":1}"#.utf8)) else { return XCTFail("missing paragraphs") }
        guard case .malformedDocument = decodeError(Data(#"{"schemaVersion":1,"paragraphs":[{"kind":"heading","runs":[]}]}"#.utf8)) else { return XCTFail("unknown kind") }
    }

    func testRejectsUnknownStyleBits() throws {
        let json = #"{"schemaVersion":1,"paragraphs":[{"kind":"plain","runs":[{"style":64,"spans":[]}]}]}"#
        guard case .malformedDocument = decodeError(Data(json.utf8)) else { return XCTFail("unknown style bit accepted") }
    }

    func testRejectsOversizedEncodedInputBeforeParsing() {
        let data = Data(count: DocumentLimits.maxEncodedBytes + 1)
        XCTAssertEqual(decodeError(data), .documentTooLarge(limit: "encodedBytes", maximum: DocumentLimits.maxEncodedBytes))
    }

    func testRejectsTooManyParagraphs() throws {
        let paragraphs = Array(repeating: Paragraph(kind: .plain, runs: []), count: DocumentLimits.maxParagraphs + 1)
        XCTAssertThrowsError(try Document(paragraphs: paragraphs).validate()) {
            XCTAssertEqual($0 as? KeyloomError, .documentTooLarge(limit: "paragraphs", maximum: DocumentLimits.maxParagraphs))
        }
    }

    func testRejectsTooMuchTextIncludingTokenSource() throws {
        let big = String(repeating: "a", count: DocumentLimits.maxTextBytes + 1)
        let literal = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal(big)])])])
        XCTAssertThrowsError(try literal.validate()) {
            XCTAssertEqual($0 as? KeyloomError, .documentTooLarge(limit: "textBytes", maximum: DocumentLimits.maxTextBytes))
        }
        let token = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.token(Token(kind: .unsupported(raw: "x"), raw: big))])])])
        XCTAssertThrowsError(try token.validate())
    }

    func testRejectsTooManySpansAndChoices() {
        let spans = Array(repeating: TemplateSpan.literal("a"), count: DocumentLimits.maxSpans + 1)
        let many = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: spans)])])
        XCTAssertThrowsError(try many.validate()) {
            XCTAssertEqual($0 as? KeyloomError, .documentTooLarge(limit: "spans", maximum: DocumentLimits.maxSpans))
        }
        let choices = Array(repeating: "c", count: DocumentLimits.maxChoices + 1)
        let kind = TokenKind.argument(name: "n", defaultValue: nil, choices: choices)
        let wide = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.token(Token(kind: kind, raw: "{argument}"))])])])
        XCTAssertThrowsError(try wide.validate()) {
            XCTAssertEqual($0 as? KeyloomError, .documentTooLarge(limit: "choices", maximum: DocumentLimits.maxChoices))
        }
    }

    func testAcceptsExactlyOneCursorAndNone() throws {
        XCTAssertNoThrow(try sampleDocument().validate())
        XCTAssertNoThrow(try Document(paragraphs: []).validate())
    }

    func testRejectsMultipleCursorsAcrossParagraphs() throws {
        var document = sampleDocument()
        document.paragraphs.append(Paragraph(kind: .plain, runs: [Run(style: [], spans: [.token(Token(kind: .cursor, raw: "{cursor}"))])]))
        XCTAssertThrowsError(try document.validate()) {
            XCTAssertEqual($0 as? KeyloomError, .multipleCursors(count: 2))
        }
        XCTAssertThrowsError(try document.encoded())
    }

    func testRejectsMultipleCursorsWhenDecoding() throws {
        var document = sampleDocument()
        document.paragraphs.append(Paragraph(kind: .plain, runs: [Run(style: [], spans: [.token(Token(kind: .cursor, raw: "{cursor}"))])]))
        let data = try JSONEncoder().encode(document)   // bypasses encoded() on purpose
        XCTAssertEqual(decodeError(data), .multipleCursors(count: 2))
    }

    func testPlainTextProjectionKeepsTokenSourceAndJoinsParagraphs() {
        let document = Document(paragraphs: [
            Paragraph(kind: .plain, runs: [Run(style: .bold, spans: [.literal("Hi "), .token(Token(kind: .argument(name: "r", defaultValue: nil, choices: []), raw: "{argument name=\"r\"}"))])]),
            Paragraph(kind: .bullet, runs: [Run(style: [], spans: [.literal("one")]), Run(style: .italic, spans: [.literal(" two")])]),
            Paragraph(kind: .numbered, runs: []),
        ])
        XCTAssertEqual(document.plainText, "Hi {argument name=\"r\"}\none two\n")
        XCTAssertEqual(Document(paragraphs: []).plainText, "")
    }
}
