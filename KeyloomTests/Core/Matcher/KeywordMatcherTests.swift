import XCTest
@testable import Keyloom

final class KeywordMatcherTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func snippet(_ keyword: String?, enabled: Bool = true) -> Snippet {
        Snippet(name: "s", icon: .emoji("x"), keyword: keyword, enabled: enabled,
                template: Document(paragraphs: []), createdAt: epoch)
    }

    private func makeMatcher(_ snippets: [Snippet]) -> (KeywordMatcher, KeywordIndexStore) {
        let store = KeywordIndexStore(KeywordIndex(snippets: snippets))
        return (KeywordMatcher(store: store), store)
    }

    /// One call per character, as a keyboard callback delivers them.
    private func type(_ text: String, into matcher: KeywordMatcher) -> [KeywordMatch] {
        text.compactMap { matcher.feed(String($0)) }
    }

    func testMatchesImmediatelyOnTheFinalCharacter() {
        let sig = snippet("::sig")
        let (matcher, _) = makeMatcher([sig])
        XCTAssertNil(matcher.feed(":"))
        XCTAssertNil(matcher.feed(":"))
        XCTAssertNil(matcher.feed("s"))
        XCTAssertNil(matcher.feed("i"))
        XCTAssertEqual(matcher.feed("g"), KeywordMatch(snippetID: sig.id, keyword: "::sig", typedUTF16Length: 5))
    }

    func testMatchesAfterUnrelatedLeadingInput() {
        let sig = snippet("::sig")
        let (matcher, _) = makeMatcher([sig])
        XCTAssertEqual(type("hello ::sig", into: matcher).map(\.snippetID), [sig.id])
    }

    func testKeywordsAreCaseSensitive() {
        let (matcher, _) = makeMatcher([snippet("::SIG")])
        XCTAssertTrue(type("::sig", into: matcher).isEmpty)
    }

    func testDisabledAndEmptyKeywordSnippetsNeverMatch() {
        let (matcher, _) = makeMatcher([snippet("::off", enabled: false), snippet(""), snippet(nil)])
        XCTAssertTrue(type("::off", into: matcher).isEmpty)
        XCTAssertEqual(matcher.bufferCapacity, 0)
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
    }

    func testFirstCompletedKeywordWinsOnPrefixOverlap() {
        let short = snippet("::a"), long = snippet("::ab")
        let (matcher, _) = makeMatcher([long, short])
        // `::a` completes before `::ab` can, so `::ab` is unreachable by typing.
        XCTAssertEqual(type("::ab", into: matcher).map(\.snippetID), [short.id])
    }

    func testBufferIsClearedAfterAMatchSoLeftoversDoNotRematch() {
        let (matcher, _) = makeMatcher([snippet("::a")])
        XCTAssertEqual(type("::a", into: matcher).count, 1)
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
        XCTAssertTrue(type("a", into: matcher).isEmpty)
    }

    func testLongestKeywordWinsWhenSeveralCompleteOnTheSameCharacter() {
        let short = snippet("b"), long = snippet("ab")
        let (matcher, _) = makeMatcher([short, long])
        XCTAssertEqual(type("ab", into: matcher).map(\.snippetID), [long.id])
        XCTAssertEqual(type("xb", into: matcher).map(\.snippetID), [short.id])
    }

    func testIdenticalKeywordsResolveToTheFirstSnippetInInputOrder() {
        let first = snippet("::dup"), second = snippet("::dup")
        let (matcher, _) = makeMatcher([first, second])
        XCTAssertEqual(type("::dup", into: matcher).map(\.snippetID), [first.id])
    }

    func testFeedingAStringStopsAtTheFirstCompletedKeyword() {
        let a = snippet("::a")
        let (matcher, _) = makeMatcher([a])
        XCTAssertEqual(matcher.feed("x::ayy")?.snippetID, a.id)
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
    }

    // MARK: Bounded buffer

    func testBufferCapacityIsTheLongestKeywordAndNothingMoreIsRetained() {
        let (matcher, _) = makeMatcher([snippet("ab"), snippet("::longest")])
        XCTAssertEqual(matcher.bufferCapacity, 9)
        _ = matcher.feed(String(repeating: "z", count: 10_000))
        XCTAssertEqual(matcher.bufferedScalarCount, 9)
    }

    func testOverlongKeywordsAreIgnored() {
        let tooLong = String(repeating: "k", count: KeywordIndex.maxKeywordScalars + 1)
        let ok = String(repeating: "k", count: KeywordIndex.maxKeywordScalars)
        let index = KeywordIndex(snippets: [snippet(tooLong), snippet(ok)])
        XCTAssertEqual(index.keywordCount, 1)
        XCTAssertEqual(index.maxKeywordLength, KeywordIndex.maxKeywordScalars)
    }

    // MARK: Invalidation

    func testInvalidateClearsTransientInput() {
        let (matcher, _) = makeMatcher([snippet("::sig")])
        _ = type("::s", into: matcher)
        matcher.invalidate()
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
        XCTAssertTrue(type("ig", into: matcher).isEmpty)
        XCTAssertEqual(type("::sig", into: matcher).count, 1)
    }

    // MARK: Index swaps

    func testSwappedIndexAppliesToTheNextCharacterWithoutRecreatingTheMatcher() {
        let old = snippet("::old"), new = snippet("::new")
        let (matcher, store) = makeMatcher([old])
        XCTAssertTrue(type("::ne", into: matcher).isEmpty)
        store.replace(KeywordIndex(snippets: [new]))
        XCTAssertEqual(matcher.feed("w")?.snippetID, new.id)
        XCTAssertEqual(type("::old", into: matcher).count, 0)
    }

    func testBufferShrinksWhenASwapLowersTheLongestKeyword() {
        let (matcher, store) = makeMatcher([snippet("::longkeyword")])
        _ = matcher.feed("::longkey")
        XCTAssertEqual(matcher.bufferedScalarCount, 9)
        store.replace(KeywordIndex(snippets: [snippet("::s")]))
        _ = matcher.feed("x")
        XCTAssertEqual(matcher.bufferedScalarCount, 3)
        store.replace(.empty)
        _ = matcher.feed("x")
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
    }

    func testStoreSwapIsAtomicUnderConcurrentFeeds() {
        let a = snippet("::a"), b = snippet("::b")
        let (matcher, store) = makeMatcher([a])
        let indexA = KeywordIndex(snippets: [a]), indexB = KeywordIndex(snippets: [b])
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            if i % 2 == 0 { store.replace(i % 4 == 0 ? indexA : indexB) } else { _ = matcher.feed("::a") }
        }
        store.replace(indexA)
        matcher.invalidate()
        XCTAssertEqual(type("::a", into: matcher).map(\.snippetID), [a.id])
    }

    // MARK: Unicode

    func testUmlautKeywordMatchesPrecomposedInput() {
        let s = snippet(";grüß")
        let (matcher, _) = makeMatcher([s])
        XCTAssertEqual(matcher.feed(";gr\u{FC}\u{DF}"), KeywordMatch(snippetID: s.id, keyword: ";grüß", typedUTF16Length: 5))
    }

    func testUmlautKeywordMatchesDecomposedInputAndCountsEveryTypedUnit() {
        let s = snippet(";grüß")
        let (matcher, _) = makeMatcher([s])
        let matches = type(";gru\u{308}\u{DF}", into: matcher)
        XCTAssertEqual(matches.map(\.snippetID), [s.id])
        XCTAssertEqual(matches.first?.typedUTF16Length, 6) // u + U+0308 were two typed units
    }

    func testDecomposedKeywordMatchesPrecomposedInput() {
        let s = snippet(";gru\u{308}")
        let (matcher, _) = makeMatcher([s])
        XCTAssertEqual(matcher.feed(";gr\u{FC}")?.snippetID, s.id)
    }

    func testCombiningMarkThatDoesNotComposeIsKeptAsItsOwnScalar() {
        let s = snippet("x\u{301}")
        let (matcher, _) = makeMatcher([s])
        XCTAssertNil(matcher.feed("x"))
        XCTAssertEqual(matcher.feed("\u{301}"), KeywordMatch(snippetID: s.id, keyword: "x\u{301}", typedUTF16Length: 2))
    }

    func testEmojiKeywordCountsSurrogatePairsInTypedLength() {
        let s = snippet(";x😀")
        let (matcher, _) = makeMatcher([s])
        XCTAssertEqual(matcher.feed(";x😀")?.typedUTF16Length, 4)
    }

    func testZWJAndSkinToneSequenceMatchesAsScalars() {
        let s = snippet(";kl👩🏽\u{200D}💻")
        let (matcher, _) = makeMatcher([s])
        let match = matcher.feed(";kl👩🏽\u{200D}💻")
        XCTAssertEqual(match?.snippetID, s.id)
        XCTAssertEqual(match?.typedUTF16Length, 3 + 4 + 1 + 2)
    }

    func testIncompleteZWJSequenceDoesNotMatch() {
        let (matcher, _) = makeMatcher([snippet(";kl👩\u{200D}💻")])
        XCTAssertNil(matcher.feed(";kl👩\u{200D}"))
        XCTAssertNil(matcher.feed("x"))
    }

    // MARK: Concurrency contract

    func testIndexAndMatcherAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(KeywordIndex.self)
        requireSendable(KeywordMatch.self)
        requireSendable(KeywordIndexStore.self)
        requireSendable(KeywordMatcher.self)
    }
}
