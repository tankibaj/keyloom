import XCTest
@testable import Keyloom

final class SnippetSearchTests: XCTestCase {
    private func snippet(_ name: String, keyword: String? = nil, tags: [String] = [], body: String = "") -> Snippet {
        let paragraphs = body.isEmpty ? [] : [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal(body)])])]
        return Snippet(name: name, icon: .emoji("x"), keyword: keyword, tags: tags,
                       template: Document(paragraphs: paragraphs), createdAt: Date(timeIntervalSince1970: 0))
    }

    private func hits(_ outcome: SearchOutcome) -> [SearchHit] {
        guard case .results(let hits) = outcome else { return [] }
        return hits
    }

    private func names(_ outcome: SearchOutcome) -> [String] {
        hits(outcome).map(\.snippet.name)
    }

    private func search(_ snippets: [Snippet], _ query: String, tags: Set<String> = []) -> SearchOutcome {
        SearchIndex(snippets: snippets).search(query: query, tags: tags)
    }

    func testEmptyLibraryIsAnExplicitEmptyResult() {
        XCTAssertEqual(search([], ""), .emptyLibrary)
        XCTAssertEqual(search([], "anything"), .emptyLibrary)
        XCTAssertEqual(search([], "", tags: ["x"]), .emptyLibrary)
    }

    func testNoMatchIsAnExplicitEmptyResult() {
        XCTAssertEqual(search([snippet("Alpha")], "zzz"), .noMatches)
    }

    func testEmptyQueryReturnsEveryoneInLibraryOrder() {
        let all = [snippet("B"), snippet("A"), snippet("C")]
        XCTAssertEqual(names(search(all, "")), ["B", "A", "C"])
        XCTAssertEqual(names(search(all, "  \n ")), ["B", "A", "C"])
        XCTAssertTrue(hits(search(all, "")).allSatisfy { $0.field == nil })
    }

    func testMatchesEachOfTheFourFields() {
        let all = [snippet("Greeting"), snippet("x", keyword: "::needle"), snippet("y", tags: ["needle"]),
                   snippet("z", body: "contains needle here"), snippet("nothing")]
        let found = hits(search(all, "needle"))
        XCTAssertEqual(found.map(\.field), [.keyword, .tag, .body])
        XCTAssertEqual(found.map(\.snippet.name), ["x", "y", "z"])
    }

    func testRankingNamePrefixThenNameThenKeywordThenTagsThenBody() {
        let all = [snippet("a", body: "foo"), snippet("b", tags: ["foo"]), snippet("c", keyword: "::foo"),
                   snippet("a foo"), snippet("foobar")]
        let found = hits(search(all, "foo"))
        XCTAssertEqual(found.map(\.snippet.name), ["foobar", "a foo", "c", "b", "a"])
        XCTAssertEqual(found.map(\.field), [.namePrefix, .name, .keyword, .tag, .body])
    }

    func testEqualRanksKeepLibraryOrder() {
        XCTAssertEqual(names(search([snippet("foo 2"), snippet("foo 1")], "fo")), ["foo 2", "foo 1"])
    }

    func testBestFieldDeterminesTheRank() {
        let both = snippet("zz", keyword: "::foo", body: "foo")
        XCTAssertEqual(search([both], "foo"), .results([SearchHit(snippet: both, field: .keyword)]))
    }

    func testCaseAndDiacriticInsensitive() {
        let all = [snippet("Grüße"), snippet("Café"), snippet("STRASSE")]
        XCTAssertEqual(names(search(all, "GRÜ")), ["Grüße"])
        XCTAssertEqual(names(search(all, "gru")), ["Grüße"])
        XCTAssertEqual(names(search(all, "cafe")), ["Café"])
        XCTAssertEqual(names(search(all, "CAFÉ")), ["Café"])
        XCTAssertEqual(names(search([snippet("Cafe\u{301}")], "café")), ["Cafe\u{301}"])
    }

    func testBodySearchUsesPlainTextProjectionAcrossParagraphsAndTokens() {
        let doc = Document(paragraphs: [
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("Dear "), .token(Token(kind: .clipboard, raw: "{clipboard}"))])]),
            Paragraph(kind: .bullet, runs: [Run(style: .bold, spans: [.literal("second line")])]),
        ])
        let s = Snippet(name: "n", icon: .emoji("x"), template: doc, createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(names(search([s], "dear {clipboard}")), ["n"])
        XCTAssertEqual(names(search([s], "SECOND")), ["n"])
    }

    func testTagFilterRequiresEveryTagSelected() {
        let all = [snippet("a", tags: ["mail", "work"]), snippet("b", tags: ["mail"]), snippet("c", tags: ["work"])]
        XCTAssertEqual(names(search(all, "", tags: ["mail"])), ["a", "b"])
        XCTAssertEqual(names(search(all, "", tags: ["mail", "work"])), ["a"])
        XCTAssertEqual(names(search(all, "", tags: ["MAIL"])), ["a", "b"])
        XCTAssertEqual(search(all, "", tags: ["none"]), .noMatches)
    }

    func testTagFilterCombinesWithQuery() {
        let all = [snippet("hello a", tags: ["mail"]), snippet("hello b", tags: ["work"])]
        XCTAssertEqual(names(search(all, "hello", tags: ["work"])), ["hello b"])
    }

    // MARK: Cost bound

    func testThousandSnippetsAreSearchedWithBoundedWork() {
        let body = String(repeating: "lorem ipsum dolor sit amet ", count: 38) // ~1 KiB each, ~1 MiB in total
        let snippets = (0..<1_000).map { snippet("Snippet \($0)", keyword: "::k\($0)", tags: ["t\($0 % 10)"], body: body) }
        XCTAssertGreaterThan(snippets.reduce(0) { $0 + $1.template.plainText.utf8.count }, 1_000_000)
        let index = SearchIndex(snippets: snippets)

        var stats = SearchStats()
        let outcome = index.search(query: "amet", tags: ["t3"], stats: &stats)
        XCTAssertEqual(names(outcome).count, 100)
        // Haystacks are folded once at build, so a query folds only itself and compares each field at most once.
        XCTAssertEqual(stats.foldOperations, 1)
        XCTAssertLessThanOrEqual(stats.fieldComparisons, 4 * snippets.count)

        var missStats = SearchStats()
        XCTAssertEqual(index.search(query: "zzzz-no-match", tags: [], stats: &missStats), .noMatches)
        XCTAssertEqual(missStats.fieldComparisons, 4 * snippets.count)
        XCTAssertEqual(missStats.foldOperations, 1)
    }
}
