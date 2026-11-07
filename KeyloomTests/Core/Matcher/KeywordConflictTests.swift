import XCTest
@testable import Keyloom

final class KeywordConflictTests: XCTestCase {
    private func snippet(_ keyword: String?, enabled: Bool = true) -> Snippet {
        Snippet(name: "s", icon: .emoji("x"), keyword: keyword, enabled: enabled,
                template: Document(paragraphs: []), createdAt: Date(timeIntervalSince1970: 0))
    }

    func testNoKeywordsMeansNoFindings() {
        XCTAssertEqual(KeywordConflicts.analyze([]), KeywordConflicts(conflicts: [], overlaps: []))
    }

    func testIdenticalActiveKeywordsAreReportedAsOneConflictWithAllIDs() {
        let a = snippet("::dup"), b = snippet("::dup"), c = snippet("::dup"), other = snippet("::x")
        let result = KeywordConflicts.analyze([a, other, b, c])
        XCTAssertEqual(result.conflicts, [KeywordConflict(keyword: "::dup", snippetIDs: [a.id, b.id, c.id])])
        XCTAssertTrue(result.overlaps.isEmpty)
    }

    func testKeywordsAreComparedCaseSensitivelyAndCanonically() {
        XCTAssertTrue(KeywordConflicts.analyze([snippet("::Sig"), snippet("::sig")]).conflicts.isEmpty)
        XCTAssertEqual(KeywordConflicts.analyze([snippet("gru\u{308}"), snippet("gr\u{FC}")]).conflicts.count, 1)
    }

    func testDisabledSnippetsAreExcluded() {
        let dup = KeywordConflicts.analyze([snippet("::dup"), snippet("::dup", enabled: false), snippet("::dup", enabled: false)])
        XCTAssertTrue(dup.conflicts.isEmpty)
        let overlap = KeywordConflicts.analyze([snippet("::a"), snippet("::ab", enabled: false)])
        XCTAssertTrue(overlap.overlaps.isEmpty)
    }

    func testEmptyAndNilKeywordsAreIgnored() {
        let result = KeywordConflicts.analyze([snippet(""), snippet(""), snippet(nil), snippet(nil), snippet("::a")])
        XCTAssertEqual(result, KeywordConflicts(conflicts: [], overlaps: []))
    }

    func testPrefixOverlapReportsTheShadowedLongerKeyword() {
        let a = snippet("::a"), ab = snippet("::ab")
        let result = KeywordConflicts.analyze([ab, a])
        XCTAssertEqual(result.overlaps, [KeywordOverlap(kind: .prefix, shorter: "::a", shorterSnippetIDs: [a.id],
                                                         longer: "::ab", longerSnippetIDs: [ab.id])])
    }

    func testSuffixOverlapIsReported() {
        let b = snippet("b"), ab = snippet("ab")
        let result = KeywordConflicts.analyze([b, ab])
        XCTAssertEqual(result.overlaps, [KeywordOverlap(kind: .suffix, shorter: "b", shorterSnippetIDs: [b.id],
                                                         longer: "ab", longerSnippetIDs: [ab.id])])
    }

    func testKeywordThatIsBothPrefixAndSuffixIsReportedOnceAsPrefix() {
        XCTAssertEqual(KeywordConflicts.analyze([snippet("a"), snippet("aa")]).overlaps.map(\.kind), [.prefix])
    }

    func testUnrelatedKeywordsDoNotOverlap() {
        XCTAssertTrue(KeywordConflicts.analyze([snippet("::a"), snippet("::b"), snippet(";c")]).overlaps.isEmpty)
    }

    func testIdenticalKeywordsAreNotAlsoReportedAsOverlappingThemselves() {
        let result = KeywordConflicts.analyze([snippet("::a"), snippet("::a")])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(result.overlaps.isEmpty)
    }

    func testOverlapListIsDeterministic() {
        let snippets = [snippet("abc"), snippet("a"), snippet("bc"), snippet("ab")]
        let result = KeywordConflicts.analyze(snippets)
        XCTAssertEqual(result.overlaps.map { "\($0.shorter)<\($0.longer):\($0.kind)" },
                       ["a<ab:prefix", "a<abc:prefix", "ab<abc:prefix", "bc<abc:suffix"])
        XCTAssertEqual(KeywordConflicts.analyze(snippets.reversed()).overlaps, result.overlaps)
    }


    func testKeywordInsideALongerOneIsReportedAsShadowing() {
        let ab = snippet("ab"), wrapped = snippet(";ab;")
        let result = KeywordConflicts.analyze([wrapped, ab])
        XCTAssertEqual(result.overlaps, [KeywordOverlap(kind: .contains, shorter: "ab", shorterSnippetIDs: [ab.id],
                                                         longer: ";ab;", longerSnippetIDs: [wrapped.id])])
    }

    func testPairAlreadyReportedAsPrefixIsNotReportedAgainAsContained() {
        XCTAssertEqual(KeywordConflicts.analyze([snippet("a"), snippet("a;a;a")]).overlaps.map(\.kind), [.prefix])
        XCTAssertEqual(KeywordConflicts.analyze([snippet("a"), snippet(";a;a")]).overlaps.map(\.kind), [.suffix])
    }

    func testContainedOverlapsAreDeterministicAndSkipDisabledAndNonOccurrences() {
        let snippets = [snippet(";ab;"), snippet("ab"), snippet("b;"), snippet("zz"), snippet("a;", enabled: false)]
        let result = KeywordConflicts.analyze(snippets)
        XCTAssertEqual(result.overlaps.map { "\($0.shorter)<\($0.longer):\($0.kind)" }, ["ab<;ab;:contains", "b;<;ab;:suffix"])
        XCTAssertEqual(KeywordConflicts.analyze(snippets.reversed()).overlaps, result.overlaps)
    }
}
