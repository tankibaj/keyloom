import XCTest
@testable import Keyloom

/// Keyword feedback and Try Expansion in the editor (slice C).
@MainActor
final class EditorFeedbackTests: LibraryUITestCase {
    private func makeEditor(_ library: SnippetLibrary, snippet: Snippet? = nil) -> EditorViewModel {
        EditorViewModel(library: library, snippet: snippet, environment: { [clock] in
            RenderEnvironment(date: clock.now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"),
                              makeUUID: { UUID() }, clipboardText: { "clip" })
        })
    }

    func testDuplicateKeywordBlocksEnablingAndNamesTheOtherSnippet() async throws {
        let library = try await openLibrary()
        try await seed(library, "Greeting", keyword: ";hi")
        let editor = makeEditor(library)
        editor.draft.name = "Hello"
        editor.draft.keyword = ";hi"
        await editor.refreshKeywordFeedback()
        XCTAssertTrue(editor.keywordFeedback.blocksEnabling)
        XCTAssertEqual(editor.keywordFeedback.conflicts, ["“Greeting” already expands from ;hi."])
        XCTAssertFalse(editor.canSave, "an enabled snippet cannot take a keyword another enabled snippet owns")

        editor.draft.enabled = false
        await editor.refreshKeywordFeedback()
        XCTAssertTrue(editor.canSave, "turning expansion off lets it be saved")

        editor.draft.enabled = true
        editor.draft.keyword = ";hello"
        await editor.refreshKeywordFeedback()
        XCTAssertTrue(editor.keywordFeedback.conflicts.isEmpty)
        XCTAssertTrue(editor.canSave)
    }

    func testAnExistingSnippetDoesNotConflictWithItsOwnKeyword() async throws {
        let library = try await openLibrary()
        let snippet = try await seed(library, "Greeting", keyword: ";hi")
        let editor = makeEditor(library, snippet: snippet)
        editor.draft.name = "Greeting 2"
        await editor.refreshKeywordFeedback()
        XCTAssertTrue(editor.keywordFeedback.conflicts.isEmpty)
        XCTAssertTrue(editor.canSave)
    }

    func testOverlapsWarnWithoutBlocking() async throws {
        let library = try await openLibrary()
        try await seed(library, "Short", keyword: ";hi")
        let editor = makeEditor(library)
        editor.draft.name = "Long"
        editor.draft.keyword = ";hi!"
        await editor.refreshKeywordFeedback()
        XCTAssertFalse(editor.keywordFeedback.blocksEnabling)
        XCTAssertEqual(editor.keywordFeedback.warnings.count, 1)
        XCTAssertTrue(editor.keywordFeedback.warnings[0].contains(";hi!"))
        XCTAssertTrue(editor.keywordFeedback.warnings[0].contains("“Short”"))
        XCTAssertTrue(editor.canSave)

        editor.draft.keyword = ";h"
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordFeedback.warnings.count, 1, "the draft as the shorter keyword is also reported")
        XCTAssertTrue(editor.keywordFeedback.warnings[0].contains("“Short”"))
    }

    func testNoKeywordOrDisabledMeansNoFeedback() async throws {
        let library = try await openLibrary()
        try await seed(library, "Greeting", keyword: ";hi")
        let editor = makeEditor(library)
        editor.draft.name = "X"
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordFeedback, KeywordFeedback())
        editor.draft.keyword = ";hi"
        editor.draft.enabled = false
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordFeedback, KeywordFeedback())
    }

    func testAConflictTheFeedbackHadNotSeenYetIsCaughtAtSave() async throws {
        let library = try await openLibrary()
        let editor = makeEditor(library)
        editor.draft.name = "Hello"
        editor.draft.keyword = ";hi"
        await editor.refreshKeywordFeedback()
        XCTAssertTrue(editor.canSave)
        try await seed(library, "Greeting", keyword: ";hi")
        let saved = await editor.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(editor.errorMessage, "Another enabled snippet already uses this keyword.")
        XCTAssertTrue(editor.keywordFeedback.blocksEnabling, "the feedback caught up")
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 1)
    }

    func testTryExpansionUsesSampleValuesOverDefaultsAndChoices() async throws {
        let editor = makeEditor(try await openLibrary())
        editor.draft.body = try document("To {argument name=\"who\" default=\"Ann\"} via {argument name=\"how\" options=\"mail, chat\"} {argument name=\"free\"}")
        XCTAssertEqual(editor.argumentRequirements.map(\.name), ["who", "how", "free"])
        guard case .rendered(let first) = editor.preview else { return XCTFail("expected a preview") }
        XCTAssertEqual(first.plainText, "To Ann via mail ‹free›", "defaults, first choice, then a named stand-in")

        editor.sampleArguments["who"] = "Bo"
        editor.sampleArguments["how"] = "chat"
        editor.sampleArguments["free"] = "anything"
        guard case .rendered(let second) = editor.preview else { return XCTFail("expected a preview") }
        XCTAssertEqual(second.plainText, "To Bo via chat anything")

        editor.sampleArguments["how"] = "carrier pigeon"
        guard case .unavailable(let message) = editor.preview else { return XCTFail("a sample outside the choices cannot render") }
        XCTAssertTrue(message.contains("how"))
    }

    func testSamplesForArgumentsThatDisappearedAreIgnored() async throws {
        let editor = makeEditor(try await openLibrary())
        editor.sampleArguments["gone"] = "x"
        editor.draft.body = try document("Plain")
        guard case .rendered(let rendered) = editor.preview else { return XCTFail("expected a preview") }
        XCTAssertEqual(rendered.plainText, "Plain")
    }
}

@MainActor
final class EditorPresentationTests: LibraryUITestCase {
    private func makeEditor(_ library: SnippetLibrary, snippet: Snippet? = nil) -> EditorViewModel {
        EditorViewModel(library: library, snippet: snippet, environment: { [clock] in
            RenderEnvironment(date: clock.now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"),
                              makeUUID: { UUID() }, clipboardText: { "(clipboard)" })
        })
    }

    func testKeywordStatusFollowsTheConflictCheck() async throws {
        let library = try await openLibrary()
        try await seed(library, "Greeting", keyword: ";hi")
        let editor = makeEditor(library)
        XCTAssertEqual(editor.keywordStatus, .none)
        editor.draft.keyword = ";hi"
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordStatus, .conflict("“Greeting” already expands from ;hi."))
        XCTAssertEqual(editor.keywordStatus.title, "Keyword in use")
        editor.draft.enabled = false
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordStatus, .off)
        editor.draft.enabled = true
        editor.draft.keyword = ";free"
        await editor.refreshKeywordFeedback()
        XCTAssertEqual(editor.keywordStatus, .free)
        XCTAssertEqual(editor.keywordStatus.title, "No conflicts")
        editor.draft.keyword = ";hix"
        await editor.refreshKeywordFeedback()
        guard case .overlap = editor.keywordStatus else { return XCTFail("a keyword that starts with another is an overlap, not a conflict") }
        XCTAssertTrue(editor.canSave == false || editor.isDirty, "an overlap never blocks")
    }

    func testPreviewResolvesPlaceholdersWithSampleArgumentsAndNoRealClipboard() async throws {
        let library = try await openLibrary()
        let snippet = try await seed(library, "Sig", keyword: nil, body: "Hi {argument name=\"who\" default=\"Ada\"} {clipboard}")
        let editor = makeEditor(library, snippet: snippet)
        guard case .rendered(let first) = editor.preview else { return XCTFail("renders") }
        XCTAssertEqual(first.segments.map(\.text).joined(), "Hi Ada (clipboard)")
        editor.sampleArguments["who"] = "Grace"
        guard case .rendered(let second) = editor.preview else { return XCTFail("renders") }
        XCTAssertEqual(second.segments.map(\.text).joined(), "Hi Grace (clipboard)")
    }

    func testUsageLineIsDeviceLocalCountsOnly() async throws {
        XCTAssertEqual(EditorViewModel.usageLine(nil), "Not used yet on this Mac.")
        XCTAssertEqual(EditorViewModel.usageLine(SnippetUsage(lastUsedAt: nil, useCount: 0)), "Not used yet on this Mac.")
        XCTAssertEqual(EditorViewModel.usageLine(SnippetUsage(lastUsedAt: Date(), useCount: 1)).prefix(9), "Used once")
        XCTAssertTrue(EditorViewModel.usageLine(SnippetUsage(lastUsedAt: Date(), useCount: 12)).hasPrefix("Used 12 times on this Mac · last used"))

        let library = try await openLibrary()
        let snippet = try await seed(library, "Sig", keyword: ";s")
        try await library.recordUsage(id: snippet.id)
        try await library.recordUsage(id: snippet.id)
        let editor = makeEditor(library, snippet: snippet)
        await editor.refreshUsage()
        XCTAssertEqual(editor.usage?.useCount, 2)
        XCTAssertTrue(editor.usageLine.hasPrefix("Used 2 times"))
        XCTAssertNil(makeEditor(library).usage)
    }
}
