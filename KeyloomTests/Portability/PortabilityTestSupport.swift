import Foundation
import XCTest
@testable import Keyloom

/// Fixtures shared by the portability and backup tests.
extension StoreTestCase {
    func literalDocument(_ text: String) -> Document {
        Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal(text)])])])
    }

    /// Every field set to a non-default value, with styled and list paragraphs and every token kind.
    func makeRichSnippet(id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, keyword: String? = ";rich") -> Snippet {
        let argument = Token(kind: .argument(name: "who", defaultValue: "team", choices: ["team", "all"]),
                             raw: "{argument name=\"who\" default=\"team\" options=\"team, all\"}")
        let styled = Run(style: [.bold, .italic], spans: [.literal("Hello "), .token(argument)])
        let plain = Run(style: [], spans: [
            .literal(" on "), .token(Token(kind: .date(format: "yyyy-MM-dd"), raw: "{date format=\"yyyy-MM-dd\"}")),
            .token(Token(kind: .unsupported(raw: "{date offset=\"+1d\"}"), raw: "{date offset=\"+1d\"}")),
        ])
        let list = Run(style: [.underline], spans: [.literal("item"), .token(Token(kind: .cursor, raw: "{cursor}"))])
        let template = Document(paragraphs: [
            Paragraph(kind: .plain, runs: [styled, plain]),
            Paragraph(kind: .bullet, runs: [list]),
            Paragraph(kind: .numbered, runs: [Run(style: [], spans: [.literal("two")])]),
        ])
        return Snippet(id: id, name: "Rich \u{1F44B}", icon: .emoji("\u{1F44B}"), keyword: keyword, enabled: false,
                       tags: ["work", "mail"], pinned: true, revision: 7, template: template,
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                       updatedAt: Date(timeIntervalSince1970: 1_700_000_500.456),
                       lastUsedAt: Date(timeIntervalSince1970: 1_700_000_900.789))
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// A native file whose entries are the encoded `snippets`, each optionally rewritten by `edit`.
    func nativeFile(_ snippets: [Snippet], edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        var file = try jsonObject(NativeFormat.export(snippets, exportedAt: clock.now))
        var entries = try XCTUnwrap(file["snippets"] as? [[String: Any]])
        edit(&entries)
        file["snippets"] = entries
        return try jsonData(file)
    }

    func assertThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line,
                                            _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}

extension StoreTestCase {
    /// `XCTUnwrap` takes a synchronous autoclosure, so an awaited value is unwrapped through this instead.
    func required<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
