import XCTest
@testable import Keyloom

/// Budgets from the release plan: p95 < 150 ms to search and rank for a warm picker, p95 < 50 ms from the last
/// typed scalar of a keyword needing no input to its plain output (accessibility insertion excluded).
final class PerformanceTests: PerfTestCase {
    private static let pickerBudgetMilliseconds = 150.0
    private static let replacementBudgetMilliseconds = 50.0
    private static let queries = ["invoice", "über", "日本語", "Regards", "q3", "no-such-text-anywhere", "", "🔑", "quick reply 5", "e\u{301}clair"]

    func testSearchCostIsOnePassOverTheLibrary() {
        let snippets = SyntheticLibrary.snippets()
        let index = SearchIndex(snippets: snippets)
        for query in Self.queries {
            var stats = SearchStats()
            _ = index.search(query: query, tags: [], stats: &stats)
            XCTAssertEqual(stats.foldOperations, 1, query)
            XCTAssertLessThanOrEqual(stats.fieldComparisons, 4 * snippets.count, query)
        }
    }

    func testWarmPickerSearchAndRankP95() async throws {
        let (library, _) = try await openFixtureLibrary()
        let milliseconds = await samples(sampleCount) { index in
            let outcome = await library.search(query: Self.queries[index % Self.queries.count])
            if case .emptyLibrary = outcome { XCTFail("library is empty") }
        }
        report("warm-picker-search", milliseconds, budgetMilliseconds: Self.pickerBudgetMilliseconds)
        let hits = await library.search(query: "")
        guard case .results(let all) = hits else { return XCTFail("expected results") }
        XCTAssertEqual(all.count, 1_000)
        await library.close()
    }

    func testMatcherIndexRebuild() {
        let snippets = SyntheticLibrary.snippets()
        let active = snippets.filter { $0.enabled && $0.keyword != nil }.count
        XCTAssertEqual(KeywordIndex(snippets: snippets).keywordCount, active)
        XCTAssertGreaterThan(active, 800)

        var milliseconds: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<sampleCount {
            let elapsed = clock.measure { _ = KeywordIndex(snippets: snippets) }
            milliseconds.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        report("matcher-index-rebuild", milliseconds)
    }

    func testEveryActiveKeywordMatchesItsSnippetOneScalarAtATime() async throws {
        let (library, _) = try await openFixtureLibrary()
        let snippets = await library.allSnippets()
        var checked = 0
        for snippet in snippets where snippet.enabled {
            guard let keyword = snippet.keyword else { continue }
            XCTAssertEqual(Self.type(keyword, into: library.keywordMatcher)?.snippetID, snippet.id, keyword)
            checked += 1
        }
        XCTAssertEqual(checked, snippets.filter { $0.enabled && $0.keyword != nil }.count)
        await library.close()
    }

    func testKeywordMatchToPlainOutputP95() async throws {
        let (library, _) = try await openFixtureLibrary()
        let noInput = await library.allSnippets().filter {
            $0.enabled && $0.keyword != nil && TemplateRenderer.requiredArguments(in: $0.template).isEmpty
        }
        XCTAssertGreaterThan(noInput.count, 500)
        let environment = renderEnvironment()
        let milliseconds = try await samples(sampleCount) { index in
            let snippet = noInput[index % noInput.count]
            let match = try XCTUnwrap(Self.type(snippet.keyword!, into: library.keywordMatcher))
            XCTAssertEqual(match.snippetID, snippet.id)
            guard case .rendered(let rendered) = try await library.expansion(for: match, environment: environment) else {
                return XCTFail("a snippet with no arguments must render directly")
            }
            XCTAssertFalse(rendered.plainText.isEmpty)
        }
        report("keyword-to-plain-output", milliseconds, budgetMilliseconds: Self.replacementBudgetMilliseconds)
        await library.close()
    }

    /// The host stays suspended until `finish` returns, so keystrokes typed meanwhile are dropped: recording usage
    /// must not reload (re-decode and re-index) the 1,000-snippet library, and must not hold `finish` up.
    func testFinishingAnExpansionNeitherReloadsNorWaitsForTheUsageWrite() async throws {
        let (library, _) = try await openFixtureLibrary()
        let environment = renderEnvironment()
        let coordinator = await MainActor.run {
            let destination = FakeDestination(prefix: "", typed: "", suffix: "")
            let permissions = FakePermissions()
            let settle: (TimeInterval) async -> Void = { _ in }
            let binder = TargetBinder(destination: destination, environment: FakeInputEnvironment(), permissions: permissions,
                                      excludedBundleIDs: { [] }, settle: settle)
            let engine = InsertionEngine(binder: binder, destination: destination, permissions: permissions,
                                         pasteboard: FakePasteboard(userClipboard: ""), keys: FakePasteKeys(), settle: settle)
            return ExpansionCoordinator(library: library, binder: binder, engine: engine, prompter: FakePrompter(),
                                        environment: { environment })
        }
        let snippets = await library.allSnippets()
        let rendered = RenderedSnippet(segments: [StyledSegment(text: "x", style: [])], plainText: "x", cursorOffset: nil)
        let reloadsBefore = await library.reloadCount

        let milliseconds = await samples(sampleCount) { index in
            _ = await coordinator.finish(.replaced(mode: .plain, verified: true, clipboard: .notTouched), rendered: rendered,
                                         snippetID: snippets[index % snippets.count].id)
        }
        await coordinator.waitForUsageRecording()

        let reloadsAfter = await library.reloadCount
        XCTAssertEqual(reloadsAfter, reloadsBefore, "no full reload per expansion")
        let recent = await library.search(query: "", filter: .recentlyUsed)
        guard case .results(let used) = recent else { return XCTFail("usage must be visible in memory") }
        XCTAssertEqual(used.count, sampleCount, "each sampled snippet shows as recently used")
        report("finish-expansion-resume", milliseconds, budgetMilliseconds: 5)
        await library.close()
    }

    func testStoreOpenAndIndexLoad() async throws {
        let (first, directory) = try await openFixtureLibrary()
        await first.close()
        let database = directory.appendingPathComponent(SyntheticLibrary.databaseName)
        let backups = directory.appendingPathComponent(SyntheticLibrary.backupsName)
        let probe = try XCTUnwrap(SyntheticLibrary.snippets().first { $0.enabled && $0.keyword != nil })

        let milliseconds = try await samples(sampleCount) { _ in
            let library = try await SnippetLibrary(url: database, backupDirectory: backups)
            let loaded = await library.allSnippets()
            XCTAssertEqual(loaded.count, 1_000)
            XCTAssertEqual(Self.type(probe.keyword!, into: library.keywordMatcher)?.snippetID, probe.id)
            await library.close()
        }
        report("store-open-and-index-load", milliseconds)
    }

    /// Feeds `text` as separate keystrokes, as the event tap does; returns the match the last one completes.
    private static func type(_ text: String, into matcher: KeywordMatcher) -> KeywordMatch? {
        matcher.invalidate()
        var match: KeywordMatch?
        for scalar in text.unicodeScalars { match = matcher.feed(String(scalar)) }
        return match
    }
}
