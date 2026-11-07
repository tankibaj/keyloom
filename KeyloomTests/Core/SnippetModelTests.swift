import XCTest
@testable import Keyloom

final class SnippetModelTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)
    private let fixedID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func makeSnippet() -> Snippet {
        Snippet(
            id: fixedID, name: "Follow-up", icon: .emoji("📧"), keyword: "::followup",
            enabled: true, tags: ["mail", "work"], pinned: true, revision: 3,
            template: Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: .bold, spans: [.literal("Hi"), .token(Token(kind: .cursor, raw: "{cursor}"))])])]),
            createdAt: created, updatedAt: created, lastUsedAt: later)
    }

    func testRenameKeepsStableIDAndBumpsRevision() throws {
        var snippet = makeSnippet()
        try snippet.rename(to: "Follow up v2", at: later)
        XCTAssertEqual(snippet.id, fixedID)
        XCTAssertEqual(snippet.name, "Follow up v2")
        XCTAssertEqual(snippet.revision, 4)
        XCTAssertEqual(snippet.updatedAt, later)
        XCTAssertEqual(snippet.createdAt, created)
    }

    func testChangingIconKeepsStableID() {
        var snippet = makeSnippet()
        snippet.setIcon(.symbol("envelope"), at: later)
        XCTAssertEqual(snippet.id, fixedID)
        XCTAssertEqual(snippet.icon, .symbol("envelope"))
        XCTAssertEqual(snippet.revision, 4)
    }

    func testRenameRejectsBlankNameWithoutChangingSnippet() {
        var snippet = makeSnippet()
        XCTAssertThrowsError(try snippet.rename(to: "  \n", at: later)) {
            XCTAssertEqual($0 as? KeyloomError, .invalidSnippet(field: "name", reason: "must not be blank"))
        }
        XCTAssertEqual(snippet, makeSnippet())
    }

    func testCodableRoundTripKeepsEveryField() throws {
        let snippet = makeSnippet()
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet))
        XCTAssertEqual(decoded, snippet)
        XCTAssertEqual(decoded.template.schemaVersion, Document.currentSchemaVersion)
    }

    func testDecodingSnippetRejectsInvalidTemplate() throws {
        var snippet = makeSnippet()
        snippet.template.paragraphs.append(snippet.template.paragraphs[0])   // second cursor
        let data = try JSONEncoder().encode(snippet)
        XCTAssertThrowsError(try JSONDecoder().decode(Snippet.self, from: data)) {
            XCTAssertEqual($0 as? KeyloomError, .multipleCursors(count: 2))
        }
    }

    func testIconRoundTripsBothKinds() throws {
        for icon in [SnippetIcon.emoji("🚀"), .symbol("star.fill")] {
            XCTAssertEqual(try JSONDecoder().decode(SnippetIcon.self, from: JSONEncoder().encode(icon)), icon)
        }
    }

    func testSymbolColorRoundTripsAndIsPartOfEquality() throws {
        let tinted = SnippetIcon.symbol("star", color: .indigo)
        XCTAssertEqual(try JSONDecoder().decode(SnippetIcon.self, from: JSONEncoder().encode(tinted)), tinted)
        XCTAssertNotEqual(tinted, .symbol("star"), "a color-only change is a real edit")
        XCTAssertEqual(Set([tinted, .symbol("star", color: .indigo), .symbol("star")]).count, 2)
        var snippet = makeSnippet()
        snippet.icon = tinted
        XCTAssertEqual(try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet)), snippet)
    }

    func testIconsWrittenBeforeColorsExistedStillDecodeAndEncodeUnchanged() throws {
        let legacy = Data(#"{"symbol":{"_0":"envelope"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SnippetIcon.self, from: legacy), .symbol("envelope", color: nil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(SnippetIcon.symbol("envelope")), as: UTF8.self), #"{"symbol":{"_0":"envelope"}}"#,
                       "no color, no key: an older build reads what this one writes")
        XCTAssertEqual(String(decoding: try encoder.encode(SnippetIcon.emoji("🚀")), as: UTF8.self), #"{"emoji":{"_0":"🚀"}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(SnippetIcon.symbol("envelope", color: .sage)), as: UTF8.self),
                       #"{"symbol":{"_0":"envelope","color":"sage"}}"#, "stored by name, never RGB")
    }

    func testThePaletteHasFifteenNamedColors() {
        XCTAssertEqual(IconColor.allCases.map(\.rawValue), ["red", "salmon", "orange", "yellow", "green", "teal", "sky", "blue",
                                                            "indigo", "purple", "violet", "pink", "gray", "sage", "tan"])
    }

    func testPublicModelTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(Snippet.self)
        requireSendable(SnippetIcon.self)
        requireSendable(IconColor.self)
        requireSendable(Document.self)
        requireSendable(Paragraph.self)
        requireSendable(Run.self)
        requireSendable(TemplateSpan.self)
        requireSendable(Token.self)
        requireSendable(TokenKind.self)
        requireSendable(TextStyle.self)
        requireSendable(KeyloomError.self)
        requireSendable(ValidatedUTF16Range.self)
    }
}
