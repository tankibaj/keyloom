import XCTest
@testable import Keyloom

final class TokenParserTests: XCTestCase {
    private struct Piece: Equatable {
        let span: TemplateSpan
        let start: Int
        let end: Int
    }

    private func pieces(_ source: String) throws -> [Piece] {
        try TokenParser.parse(source).spans.map { Piece(span: $0.span, start: $0.sourceRange.start, end: $0.sourceRange.end) }
    }

    private func token(_ kind: TokenKind, _ raw: String) -> TemplateSpan { .token(Token(kind: kind, raw: raw)) }

    private func parseError(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> TemplateParseError? {
        do {
            _ = try TokenParser.parse(source)
            XCTFail("expected parse to fail for \(source)", file: file, line: line)
            return nil
        } catch {
            return error as? TemplateParseError
        }
    }

    private func range(_ start: Int, _ end: Int, in source: String) throws -> ValidatedUTF16Range {
        try ValidatedUTF16Range(start: start, end: end, in: source)
    }

    // MARK: exact spans

    func testSupportedTokensAndExactUTF16Spans() throws {
        let dateRaw = #"{date format="yyyy-MM-dd"}"#
        let argRaw = #"{argument name="recipient" default="team" options="team, Sam"}"#
        let table: [(String, [Piece])] = [
            ("", []),
            ("plain", [Piece(span: .literal("plain"), start: 0, end: 5)]),
            ("{uuid}", [Piece(span: token(.uuid, "{uuid}"), start: 0, end: 6)]),
            ("a{clipboard}b", [
                Piece(span: .literal("a"), start: 0, end: 1),
                Piece(span: token(.clipboard, "{clipboard}"), start: 1, end: 12),
                Piece(span: .literal("b"), start: 12, end: 13),
            ]),
            ("{cursor}", [Piece(span: token(.cursor, "{cursor}"), start: 0, end: 8)]),
            ("{date}{time}", [
                Piece(span: token(.date(format: nil), "{date}"), start: 0, end: 6),
                Piece(span: token(.time(format: nil), "{time}"), start: 6, end: 12),
            ]),
            ("On \(dateRaw).", [
                Piece(span: .literal("On "), start: 0, end: 3),
                Piece(span: token(.date(format: "yyyy-MM-dd"), dateRaw), start: 3, end: 29),
                Piece(span: .literal("."), start: 29, end: 30),
            ]),
            (#"{time format="HH:mm"}"#, [Piece(span: token(.time(format: "HH:mm"), #"{time format="HH:mm"}"#), start: 0, end: 21)]),
            (argRaw, [Piece(span: token(.argument(name: "recipient", defaultValue: "team", choices: ["team", "Sam"]), argRaw), start: 0, end: 62)]),
            (#"{argument name="x"}"#, [Piece(span: token(.argument(name: "x", defaultValue: nil, choices: []), #"{argument name="x"}"#), start: 0, end: 19)]),
            // Offsets count UTF-16 units: a surrogate pair is 2, a combining sequence is 2.
            ("😀{uuid}", [
                Piece(span: .literal("😀"), start: 0, end: 2),
                Piece(span: token(.uuid, "{uuid}"), start: 2, end: 8),
            ]),
            ("e\u{301}{cursor}x", [
                Piece(span: .literal("e\u{301}"), start: 0, end: 2),
                Piece(span: token(.cursor, "{cursor}"), start: 2, end: 10),
                Piece(span: .literal("x"), start: 10, end: 11),
            ]),
            ("👨‍👩‍👧{cursor}", [
                Piece(span: .literal("👨‍👩‍👧"), start: 0, end: 8),
                Piece(span: token(.cursor, "{cursor}"), start: 8, end: 16),
            ]),
        ]
        for (source, expected) in table {
            XCTAssertEqual(try pieces(source), expected, source)
        }
    }

    func testSpansAreSliceableAndTileTheSource() throws {
        let source = #"é{date}😀{argument name="a"} {uuid}"#
        let spans = try TokenParser.parse(source).spans
        var cursor = 0
        for span in spans {
            XCTAssertEqual(span.sourceRange.start, cursor)
            cursor = span.sourceRange.end
            let text = String(source[try span.sourceRange.stringRange(in: source)])
            switch span.span {
            case .token(let token): XCTAssertEqual(token.raw, text)
            case .literal(let literal): XCTAssertEqual(literal, text)
            }
        }
        XCTAssertEqual(cursor, source.utf16.count)
    }

    func testQuotedValuesMayContainBracesAndEscapedQuotes() throws {
        let braces = #"{date format="'{'yyyy"}"#
        XCTAssertEqual(try pieces(braces).first?.span, token(.date(format: "'{'yyyy"), braces))
        let quoted = #"{argument name="x" default="say \"hi\""}"#
        XCTAssertEqual(try pieces(quoted).first?.span, token(.argument(name: "x", defaultValue: #"say "hi""#, choices: []), quoted))
    }

    func testOptionsAreTrimmedAndEmptyEntriesDropped() throws {
        let raw = #"{argument name="x" options=" a ,, b ,"}"#
        XCTAssertEqual(try pieces(raw).first?.span, token(.argument(name: "x", defaultValue: nil, choices: ["a", "b"]), raw))
    }

    // MARK: unsupported tokens

    func testUnsupportedTokensStayLiteralAndAreFlagged() throws {
        let sources = ["{foo}", "{}", "{ date }", #"{date offset="+1d"}"#, #"{uuid x="1"}"#, #"{"a":1}"#, "{date-x}", #"{cursor now="1"}"#, #"{argument name="x" extra="1"}"#]
        for source in sources {
            let parsed = try TokenParser.parse(source)
            XCTAssertEqual(parsed.spans.map(\.span), [token(.unsupported(raw: source), source)], source)
            XCTAssertEqual(parsed.unsupported, [try range(0, source.utf16.count, in: source)], source)
        }
    }

    func testSupportedTokensAreNotFlagged() throws {
        XCTAssertTrue(try TokenParser.parse("{date}{time}{uuid}{clipboard}{cursor}{argument name=\"a\"}").unsupported.isEmpty)
    }

    func testUnsupportedRangesPointAtEachOccurrence() throws {
        let source = "ab{foo}c{bar}"
        XCTAssertEqual(try TokenParser.parse(source).unsupported, [try range(2, 7, in: source), try range(8, 13, in: source)])
    }

    // MARK: escapes

    func testEscapedBracesAndBackslashAreLiteral() throws {
        let table: [(String, [Piece])] = [
            (#"\{date\}"#, [Piece(span: .literal("{date}"), start: 0, end: 8)]),
            (#"a\\b"#, [Piece(span: .literal(#"a\b"#), start: 0, end: 4)]),
            (#"\x"#, [Piece(span: .literal(#"\x"#), start: 0, end: 2)]),
            ("a}b", [Piece(span: .literal("a}b"), start: 0, end: 3)]),
            (#"\{{uuid}"#, [
                Piece(span: .literal("{"), start: 0, end: 2),
                Piece(span: token(.uuid, "{uuid}"), start: 2, end: 8),
            ]),
            (#"x\"#, [Piece(span: .literal(#"x\"#), start: 0, end: 2)]),
        ]
        for (source, expected) in table {
            XCTAssertEqual(try pieces(source), expected, source)
        }
        XCTAssertTrue(try TokenParser.parse(#"\{date\}"#).unsupported.isEmpty)
    }

    // MARK: malformed input

    func testMalformedInputGivesTypedErrors() throws {
        let table: [(String, TemplateParseError)] = [
            ("Hello {date", .unterminatedToken(offset: 6)),
            (#"{argument name="a}"#, .unterminatedToken(offset: 0)),
            ("{", .unterminatedToken(offset: 0)),
            ("{argument}", .emptyArgumentName(try range(0, 10, in: "{argument}"))),
            (#"{argument name=""}"#, .emptyArgumentName(try range(0, 18, in: #"{argument name=""}"#))),
            (#"{argument name="  "}"#, .emptyArgumentName(try range(0, 20, in: #"{argument name="  "}"#))),
            ("{date format=yyyy}", .malformedToken(try range(0, 18, in: "{date format=yyyy}"))),
            ("{date format}", .malformedToken(try range(0, 13, in: "{date format}"))),
            (#"{date format="a"x}"#, .malformedToken(try range(0, 18, in: #"{date format="a"x}"#))),
            (#"{date format="a" format="b"}"#, .malformedToken(try range(0, 28, in: #"{date format="a" format="b"}"#))),
            (#"{date format=""}"#, .malformedToken(try range(0, 16, in: #"{date format=""}"#))),
            ("{date =\"a\"}", .malformedToken(try range(0, 11, in: "{date =\"a\"}"))),
        ]
        for (source, expected) in table {
            XCTAssertEqual(parseError(source), expected, source)
        }
    }

    func testDefaultOutsideOptionsIsRejected() throws {
        let source = #"{argument name="x" default="c" options="a, b"}"#
        XCTAssertEqual(parseError(source), .defaultNotInOptions(name: "x", try range(0, source.utf16.count, in: source)))
    }

    func testConflictingDefinitionsOfOneNameAreRejected() throws {
        let defaults = #"{argument name="x" default="1"}{argument name="x" default="2"}"#
        XCTAssertEqual(parseError(defaults), .conflictingArgument(name: "x", try range(31, 62, in: defaults)))
        let options = #"{argument name="x" options="a,b"}{argument name="x" options="a,c"}"#
        XCTAssertEqual(parseError(options), .conflictingArgument(name: "x", try range(33, 66, in: options)))
        let lateDefault = #"{argument name="x" options="a,b"}{argument name="x" default="c"}"#
        XCTAssertEqual(parseError(lateDefault), .defaultNotInOptions(name: "x", try range(33, 64, in: lateDefault)))
    }

    func testRepeatedNamesWithCompatibleDefinitionsParse() throws {
        let source = #"{argument name="x" default="a" options="a,b"}{argument name="x"}{argument name="x" default="a"}{argument name="y"}"#
        XCTAssertEqual(try TokenParser.parse(source).spans.count, 4)
    }

    func testSecondCursorIsRejected() throws {
        let source = "{cursor}a{cursor}"
        XCTAssertEqual(parseError(source), .multipleCursors(try range(9, 17, in: source)))
    }

    func testErrorsCarryOffsetsNotTemplateText() throws {
        let source = "secret text {date format=oops} more"
        XCTAssertEqual(parseError(source), .malformedToken(try range(12, 30, in: source)))
    }

    // MARK: document

    func testDocumentSplitsLiteralNewlinesIntoParagraphs() throws {
        let document = try TokenParser.parse("Hi {uuid}\n\nBye{cursor}").document
        XCTAssertEqual(document.paragraphs.count, 3)
        XCTAssertEqual(document.paragraphs[0].runs, [Run(style: [], spans: [.literal("Hi "), token(.uuid, "{uuid}")])])
        XCTAssertEqual(document.paragraphs[1].runs, [Run(style: [], spans: [])])
        XCTAssertEqual(document.paragraphs[2].runs, [Run(style: [], spans: [.literal("Bye"), token(.cursor, "{cursor}")])])
        XCTAssertNoThrow(try document.validate())
        XCTAssertEqual(document.plainText, "Hi {uuid}\n\nBye{cursor}")
    }
}
