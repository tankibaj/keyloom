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

    func testPublicModelTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(Snippet.self)
        requireSendable(SnippetIcon.self)
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
