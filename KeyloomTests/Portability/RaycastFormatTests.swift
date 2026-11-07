import XCTest
@testable import Keyloom

final class RaycastFormatTests: StoreTestCase {
    private func decode(_ json: String) throws -> DecodedImport {
        try RaycastFormat.decode(Data(json.utf8), now: clock.now, makeID: { [ids] in ids.next() })
    }

    // MARK: Import

    func testImportsNameTextKeywordRecordsAndIgnoresOtherKeys() throws {
        let decoded = try decode(#"""
        [{"name": "Sig", "text": "Best,\nNaim", "keyword": ";sig", "type": "snippet"},
         {"name": "No keyword", "text": "x"},
         {"name": "Empty keyword", "text": "y", "keyword": ""}]
        """#)
        XCTAssertEqual(decoded.format, .raycast)
        XCTAssertEqual(decoded.malformed, [])
        let snippets = decoded.candidates.map(\.snippet)
        XCTAssertEqual(snippets.map(\.name), ["Sig", "No keyword", "Empty keyword"])
        XCTAssertEqual(snippets.map(\.keyword), [";sig", nil, nil])
        XCTAssertEqual(snippets[0].template.paragraphs.count, 2, "a newline starts a new paragraph")
        XCTAssertEqual(snippets[0].template.plainText, "Best,\nNaim")
        XCTAssertEqual(Set(snippets.map(\.id)).count, 3, "ids come from the injected generator")
        XCTAssertTrue(snippets.allSatisfy { $0.enabled && $0.revision == 1 && $0.createdAt == clock.now })
    }

    func testCRLFAndLoneCRBecomeParagraphBreaksAndKeywordIsNFC() throws {
        let decoded = try decode(#"[{"name": "A", "text": "one\r\ntwo\rthree", "keyword": "e\u0301x"}]"#)
        let snippet = try XCTUnwrap(decoded.candidates.first?.snippet)
        XCTAssertEqual(snippet.template.plainText, "one\ntwo\nthree")
        XCTAssertEqual(snippet.keyword, "\u{00E9}x")
    }

    func testSupportedTokensAreParsed() throws {
        let decoded = try decode(#"[{"name": "A", "text": "{clipboard} and {cursor}"}]"#)
        let kinds = try XCTUnwrap(decoded.candidates.first).snippet.template.paragraphs[0].runs[0].spans.compactMap { span -> TokenKind? in
            if case .token(let token) = span { return token.kind }
            return nil
        }
        XCTAssertEqual(kinds, [.clipboard, .cursor])
        XCTAssertEqual(decoded.candidates.first?.unsupportedTokens, [])
    }

    func testUnsupportedTokensArePreservedLiterallyAndFlagged() throws {
        let text = #"Hi {date offset=\"+1d\"} {snippet name=\"x\"}"#
        let decoded = try decode(#"[{"name": "A", "text": "\#(text)"}]"#)
        let candidate = try XCTUnwrap(decoded.candidates.first)
        XCTAssertEqual(candidate.unsupportedTokens, [#"{date offset="+1d"}"#, #"{snippet name="x"}"#])
        XCTAssertEqual(candidate.snippet.template.plainText, #"Hi {date offset="+1d"} {snippet name="x"}"#)
        XCTAssertFalse(candidate.templateKeptLiteral)
    }

    func testTemplateWithBrokenTokenSyntaxIsKeptAsLiteralTextAndFlagged() throws {
        let decoded = try decode(#"[{"name": "Code", "text": "function() {\n  return 1;"}]"#)
        let candidate = try XCTUnwrap(decoded.candidates.first)
        XCTAssertTrue(candidate.templateKeptLiteral)
        XCTAssertEqual(candidate.snippet.template.plainText, "function() {\n  return 1;")
        XCTAssertEqual(decoded.malformed, [])
    }

    func testMalformedRecordsAreListedAndTheRestImported() throws {
        let decoded = try decode(#"""
        [{"name": "ok", "text": "t"}, 7, {"text": "no name"}, {"name": "  ", "text": "t"}, {"name": "no text"},
         {"name": "n", "text": 5}, {"name": "n", "text": "t", "keyword": 3}]
        """#)
        XCTAssertEqual(decoded.candidates.map(\.index), [0])
        XCTAssertEqual(decoded.malformed.map(\.index), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(decoded.malformed.map(\.reason), [
            .invalidStructure, .missingField("name"), .invalidField("name"), .missingField("text"),
            .invalidField("text"), .invalidField("keyword"),
        ])
    }

    func testFileLevelFailuresAreTyped() {
        assertThrows(PortabilityError.notRecognized) { _ = try self.decode(#"{"name": "A"}"#) }
        assertThrows(PortabilityError.malformedFile) { _ = try self.decode(#"[{"name": "A", "text":"#) }
        assertThrows(PortabilityError.fileTooLarge(maximumBytes: ImportLimits.maxFileBytes)) {
            _ = try RaycastFormat.decode(Data(count: ImportLimits.maxFileBytes + 1), now: self.clock.now, makeID: { UUID() })
        }
        let crowded = "[" + Array(repeating: "{}", count: ImportLimits.maxEntries + 1).joined(separator: ",") + "]"
        assertThrows(PortabilityError.tooManyEntries(maximum: ImportLimits.maxEntries)) { _ = try self.decode(crowded) }
    }

    // MARK: Export

    func testExportWritesNameTextKeywordAndOmitsAMissingKeyword() throws {
        let plain = makeSnippet(name: "Hi", keyword: ";hi", text: "Hello")
        let bare = makeSnippet(name: "Bare", keyword: nil, text: "x")
        let export = try RaycastFormat.export([plain, bare])
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: export.data) as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["name"] as? String, "Hi")
        XCTAssertEqual(records[0]["text"] as? String, "Hello")
        XCTAssertEqual(records[0]["keyword"] as? String, ";hi")
        XCTAssertNil(records[1]["keyword"])
        XCTAssertEqual(Set(records[0].keys), ["name", "text", "keyword"])
        XCTAssertEqual(export.losses, [])
    }

    func testExportedTextReimportsToTheSamePlainTextIncludingLiteralBracesAndTokens() throws {
        let tricky = "C:\\dir \\{ { } \\\\{ } end\\"
        let template = Document(paragraphs: [
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [
                .literal(tricky), .token(Token(kind: .date(format: "yyyy"), raw: "{date format=\"yyyy\"}")),
            ])]),
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("second line")])]),
        ])
        let original = Snippet(id: ids.next(), name: "T", icon: .symbol("x"), keyword: ";t", template: template, createdAt: clock.now)
        let export = try RaycastFormat.export([original])
        let back = try RaycastFormat.decode(export.data, now: clock.now, makeID: { [ids] in ids.next() })
        let reimported = try XCTUnwrap(back.candidates.first)
        XCTAssertEqual(reimported.snippet.template.plainText, original.template.plainText)
        XCTAssertEqual(reimported.snippet.template.paragraphs[0].runs[0].spans, original.template.paragraphs[0].runs[0].spans)
        XCTAssertFalse(reimported.templateKeptLiteral)
    }

    func testLossPreviewNamesEachKindOfFormattingAndMetadataThatRaycastCannotHold() throws {
        let rich = makeRichSnippet()
        let plain = makeSnippet(id: ids.next(), name: "Plain")
        let styledOnly = Snippet(id: ids.next(), name: "S", icon: .symbol("x"), keyword: ";s",
                                 template: Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: .bold, spans: [.literal("b")])])]),
                                 createdAt: clock.now)
        let losses = RaycastFormat.losses(in: [rich, plain, styledOnly])
        XCTAssertEqual(losses, [
            FormattingLoss(snippetID: rich.id, kinds: [.textStyles, .listFormatting, .tags, .pinned, .disabled]),
            FormattingLoss(snippetID: styledOnly.id, kinds: [.textStyles]),
        ])
        XCTAssertEqual(try RaycastFormat.export([rich, plain, styledOnly]).losses, losses)
    }
}
