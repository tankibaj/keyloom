import os
import XCTest
@testable import Keyloom

final class RendererTests: XCTestCase {
    /// 2026-01-15 14:05:09 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_768_485_909)
    private let posix = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(identifier: "UTC")!

    private func environment(timeZone: TimeZone? = nil, locale: Locale? = nil, clipboard: String? = nil,
                             uuid: @escaping @Sendable () -> UUID = { UUID(uuidString: "00000000-0000-0000-0000-00000000000A")! },
                             clipboardReads: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)) -> RenderEnvironment {
        RenderEnvironment(date: fixedDate, timeZone: timeZone ?? utc, locale: locale ?? posix, makeUUID: uuid,
                          clipboardText: { clipboardReads.withLock { $0 += 1 }; return clipboard })
    }

    private func renderer(_ environment: RenderEnvironment? = nil) -> TemplateRenderer {
        TemplateRenderer(environment: environment ?? self.environment())
    }

    private func document(_ source: String) throws -> Document { try TokenParser.parse(source).document }

    private func styled(_ runs: [Run], kind: ParagraphKind = .plain) -> Document {
        Document(paragraphs: [Paragraph(kind: kind, runs: runs)])
    }

    private func arg(_ name: String, default defaultValue: String? = nil, choices: [String] = []) -> TemplateSpan {
        .token(Token(kind: .argument(name: name, defaultValue: defaultValue, choices: choices), raw: "{argument name=\"\(name)\"}"))
    }

    private func assertAgree(_ rendered: RenderedSnippet, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rendered.segments.map(\.text).joined(), rendered.plainText, file: file, line: line)
    }

    // MARK: substitution

    func testDateAndTimeUseInjectedFormatTimeZoneAndLocale() throws {
        let doc = try document(#"{date format="yyyy-MM-dd"} {time format="HH:mm:ss"}"#)
        XCTAssertEqual(try renderer().render(doc).plainText, "2026-01-15 14:05:09")
        // 14:05 UTC is already the next day in Auckland (UTC+13).
        let auckland = environment(timeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(try renderer(auckland).render(doc).plainText, "2026-01-16 03:05:09")
        let german = environment(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(try renderer(german).render(try document(#"{date format="MMMM"}"#)).plainText, "Januar")
        XCTAssertEqual(try renderer(environment(locale: Locale(identifier: "en_US"))).render(try document(#"{date format="MMMM"}"#)).plainText, "January")
    }

    func testDefaultDateAndTimeFollowTheLocale() throws {
        let german = renderer(environment(locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(try german.render(try document("{date}")).plainText, "15.01.2026")
        XCTAssertEqual(try german.render(try document("{time}")).plainText, "14:05")
    }

    func testUUIDIsGeneratedPerOccurrenceFromTheInjectedGenerator() throws {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let env = environment(uuid: {
            let next = counter.withLock { value -> Int in value += 1; return value }
            return UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", next))!
        })
        XCTAssertEqual(try renderer(env).render(try document("{uuid} {uuid}")).plainText,
                       "00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002")
    }

    func testClipboardIsReadOncePerRenderAndMissingTextIsEmpty() throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let env = environment(clipboard: "pasted", clipboardReads: reads)
        XCTAssertEqual(try renderer(env).render(try document("[{clipboard}|{clipboard}]")).plainText, "[pasted|pasted]")
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertEqual(try renderer(environment(clipboard: nil)).render(try document("[{clipboard}]")).plainText, "[]")
        let none = OSAllocatedUnfairLock(initialState: 0)
        _ = try renderer(environment(clipboardReads: none)).render(try document("no tokens"))
        XCTAssertEqual(none.withLock { $0 }, 0, "clipboard must not be read when the template does not use it")
    }

    func testSubstitutedValuesAreNeverReparsedAsTokens() throws {
        let doc = try document(#"a{argument name="x"}b{cursor}"#)
        let rendered = try renderer().render(doc, arguments: ["x": "{cursor}{uuid}"])
        XCTAssertEqual(rendered.plainText, "a{cursor}{uuid}b")
        XCTAssertEqual(rendered.cursorOffset, 16)
    }

    func testUnsupportedTokenStaysLiteral() throws {
        let rendered = try renderer().render(try document(#"x {foo} {date offset="+1d"} y"#))
        XCTAssertEqual(rendered.plainText, #"x {foo} {date offset="+1d"} y"#)
    }

    func testEscapedBracesRenderAsLiteralBraces() throws {
        XCTAssertEqual(try renderer().render(try document(#"\{uuid\}"#)).plainText, "{uuid}")
    }

    // MARK: style

    func testSubstitutedValuesInheritTheSurroundingRunStyle() throws {
        let doc = styled([
            Run(style: [], spans: [.literal("Hi ")]),
            Run(style: [.bold, .underline], spans: [arg("who"), .literal("/"), .token(Token(kind: .uuid, raw: "{uuid}"))]),
            Run(style: .italic, spans: [.token(Token(kind: .unsupported(raw: "{foo}"), raw: "{foo}"))]),
        ])
        let rendered = try renderer().render(doc, arguments: ["who": "Sam"])
        XCTAssertEqual(rendered.segments, [
            StyledSegment(text: "Hi ", style: []),
            StyledSegment(text: "Sam/00000000-0000-0000-0000-00000000000A", style: [.bold, .underline]),
            StyledSegment(text: "{foo}", style: .italic),
        ])
        assertAgree(rendered)
    }

    func testStyledAndPlainAgreeForTheFollowUpExample() throws {
        let doc = try document("Hi {argument name=\"recipient\"},\n\nOn {date format=\"yyyy-MM-dd\"} thanks.{cursor}")
        let rendered = try renderer().render(doc, arguments: ["recipient": "Sam"])
        XCTAssertEqual(rendered.plainText, "Hi Sam,\n\nOn 2026-01-15 thanks.")
        assertAgree(rendered)
        XCTAssertEqual(rendered.cursorOffset, rendered.plainText.utf16.count)
    }

    func testListMarkersAreRenderedIntoBothRepresentations() throws {
        let doc = Document(paragraphs: [
            Paragraph(kind: .bullet, runs: [Run(style: .bold, spans: [.literal("a")])]),
            Paragraph(kind: .numbered, runs: [Run(style: [], spans: [.literal("b")])]),
            Paragraph(kind: .numbered, runs: [Run(style: [], spans: [.literal("c")])]),
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("d")])]),
            Paragraph(kind: .numbered, runs: [Run(style: [], spans: [.literal("e")])]),
        ])
        let rendered = try renderer().render(doc)
        XCTAssertEqual(rendered.plainText, "• a\n1. b\n2. c\nd\n1. e")
        assertAgree(rendered)
        XCTAssertEqual(rendered.segments.first { $0.text == "a" }?.style, .bold)
        XCTAssertEqual(rendered.segments.first?.style, [], "list markers are unstyled")
    }

    // MARK: cursor

    func testCursorOffsetIsUTF16AfterEmojiAndCombiningMarks() throws {
        let table: [(String, Int)] = [
            ("{cursor}", 0),
            ("abc{cursor}", 3),
            ("😀{cursor}x", 2),
            ("e\u{301}{cursor}", 2),
            ("👨‍👩‍👧{cursor}", 8),
            ("e{cursor}\u{301}", 1),
            ("a\n😀 {cursor}", 5),
        ]
        for (source, expected) in table {
            let rendered = try renderer().render(try document(source))
            XCTAssertEqual(rendered.cursorOffset, expected, source)
            XCTAssertNoThrow(try rendered.plainText.validatedCursor(utf16Offset: expected), source)
        }
    }

    func testCursorCountsSubstitutedValuesAndListMarkers() throws {
        let doc = Document(paragraphs: [Paragraph(kind: .bullet, runs: [Run(style: [], spans: [arg("x"), .token(Token(kind: .cursor, raw: "{cursor}"))])])])
        let rendered = try renderer().render(doc, arguments: ["x": "😀\u{E9}"])
        XCTAssertEqual(rendered.plainText, "• 😀\u{E9}")
        XCTAssertEqual(rendered.cursorOffset, 5)
    }

    func testNoCursorMeansNilOffset() throws {
        XCTAssertNil(try renderer().render(try document("plain")).cursorOffset)
    }

    func testDocumentWithTwoCursorsIsRejected() {
        let cursor = TemplateSpan.token(Token(kind: .cursor, raw: "{cursor}"))
        let doc = styled([Run(style: [], spans: [cursor, cursor])])
        XCTAssertThrowsError(try renderer().render(doc)) { XCTAssertEqual($0 as? KeyloomError, .multipleCursors(count: 2)) }
    }

    // MARK: arguments

    func testRepeatedNamesReuseOneAnswerAndOnePrompt() throws {
        let doc = try document(#"{argument name="who"} and {argument name="who"}, {argument name="other" default="o"}"#)
        XCTAssertEqual(TemplateRenderer.requiredArguments(in: doc).map(\.name), ["who", "other"])
        XCTAssertEqual(try renderer().render(doc, arguments: ["who": "Sam"]).plainText, "Sam and Sam, o")
    }

    func testDefaultsFillInWhenNoValueIsProvided() throws {
        let doc = try document(#"{argument name="a" default="team"}|{argument name="a"}"#)
        XCTAssertEqual(try renderer().render(doc).plainText, "team|team")
        XCTAssertEqual(try renderer().render(doc, arguments: ["a": "Sam"]).plainText, "Sam|Sam")
    }

    func testProvidedEmptyStringCountsAsAnAnswer() throws {
        let doc = try document(#"[{argument name="a" default="team"}]"#)
        XCTAssertEqual(try renderer().render(doc, arguments: ["a": ""]).plainText, "[]")
        XCTAssertTrue(TemplateRenderer.requiredArguments(in: doc, provided: ["a": ""]).isEmpty)
    }

    func testRequiredArgumentsListWhatMustBePromptedInSourceOrderWithMergedDefinitions() throws {
        let doc = try document(#"{argument name="b" options="x, y"}{argument name="a" default="d"}{argument name="b" default="x"}"#)
        XCTAssertEqual(TemplateRenderer.requiredArguments(in: doc), [
            ArgumentRequirement(name: "b", defaultValue: "x", choices: ["x", "y"]),
            ArgumentRequirement(name: "a", defaultValue: "d", choices: []),
        ])
        XCTAssertEqual(TemplateRenderer.requiredArguments(in: doc, provided: ["b": "y"]).map(\.name), ["a"])
    }

    func testDirectExpansionWhenAllValuesAreProvidedOrTemplateHasNoArguments() throws {
        let doc = try document(#"Hi {argument name="a"} {argument name="b" options="p, q"}"#)
        XCTAssertFalse(TemplateRenderer.requiredArguments(in: doc).isEmpty)
        let provided = ["a": "Sam", "b": "q"]
        XCTAssertTrue(TemplateRenderer.requiredArguments(in: doc, provided: provided).isEmpty)
        XCTAssertEqual(try renderer().render(doc, arguments: provided).plainText, "Hi Sam q")
        XCTAssertTrue(TemplateRenderer.requiredArguments(in: try document("{date}{cursor}")).isEmpty)
    }

    func testMissingArgumentsWithoutDefaultAreReportedTogether() throws {
        let doc = try document(#"{argument name="b"}{argument name="a" default="d"}{argument name="c"}{argument name="b"}"#)
        XCTAssertThrowsError(try renderer().render(doc, arguments: [:])) {
            XCTAssertEqual($0 as? RenderError, .missingArguments(names: ["b", "c"]))
        }
    }

    func testChoiceOutsideOptionsIsRejectedAndInsideAccepted() throws {
        let doc = try document(#"{argument name="size" options="small, large"}"#)
        XCTAssertThrowsError(try renderer().render(doc, arguments: ["size": "huge"])) {
            XCTAssertEqual($0 as? RenderError, .choiceNotInOptions(name: "size"))
        }
        XCTAssertThrowsError(try renderer().render(doc, arguments: ["size": "Small"]), "choices are case-sensitive")
        XCTAssertEqual(try renderer().render(doc, arguments: ["size": "large"]).plainText, "large")
    }

    func testDefaultOutsideOptionsInAnUnparsedDocumentIsRejected() {
        let doc = styled([Run(style: [], spans: [arg("size", default: "huge", choices: ["small"])])])
        XCTAssertThrowsError(try renderer().render(doc)) { XCTAssertEqual($0 as? RenderError, .choiceNotInOptions(name: "size")) }
    }

    func testErrorsNeverContainArgumentValues() {
        let doc = styled([Run(style: [], spans: [arg("size", choices: ["small"])])])
        XCTAssertThrowsError(try renderer().render(doc, arguments: ["size": "TOPSECRET"])) {
            XCTAssertFalse(String(describing: $0).contains("TOPSECRET"))
        }
    }

    func testUnusedArgumentValuesAreIgnored() throws {
        XCTAssertEqual(try renderer().render(try document("hi"), arguments: ["zzz": "1"]).plainText, "hi")
    }
}
