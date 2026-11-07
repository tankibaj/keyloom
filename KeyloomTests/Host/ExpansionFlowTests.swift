import XCTest
@testable import Keyloom

/// Match -> bind -> expand (real library) -> prompt -> revalidate -> write, with fakes only at the OS boundary.
@MainActor
final class ExpansionFlowTests: StoreTestCase {
    private var library: SnippetLibrary!
    private var destination: FakeDestination!
    private var environment: FakeInputEnvironment!
    private var permissions: FakePermissions!
    private var pasteboard: FakePasteboard!
    private var prompter: FakePrompter!
    private var coordinator: ExpansionCoordinator!
    private var excluded: Set<String> = []

    private func setUpFlow(prefix: String = "Dear ", typed: String, suffix: String = " tail") async throws {
        let url = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        library = try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                           now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        destination = FakeDestination(prefix: prefix, typed: typed, suffix: suffix)
        environment = FakeInputEnvironment()
        permissions = FakePermissions()
        pasteboard = FakePasteboard(userClipboard: "user clipboard")
        prompter = FakePrompter()
        excluded = []
        let settle: (TimeInterval) async -> Void = { _ in }
        let binder = TargetBinder(destination: destination, environment: environment, permissions: permissions,
                                  excludedBundleIDs: { [unowned self] in excluded }, settle: settle)
        let engine = InsertionEngine(binder: binder, destination: destination, permissions: permissions, pasteboard: pasteboard,
                                     keys: FakePasteKeys(), settle: settle)
        coordinator = ExpansionCoordinator(library: library, binder: binder, engine: engine, prompter: prompter,
                                           environment: { Self.renderEnvironment })
        addTeardownBlock { [library] in await library?.close() }
    }

    private static let renderEnvironment = RenderEnvironment(
        date: Date(timeIntervalSince1970: 1_768_485_909), timeZone: TimeZone(identifier: "UTC")!,
        locale: Locale(identifier: "en_US_POSIX"), makeUUID: { UUID() }, clipboardText: { nil })

    @discardableResult
    private func addSnippet(_ keyword: String, _ template: String) async throws -> Snippet {
        try await library.create(name: keyword, icon: .emoji("x"), keyword: keyword, enabled: true, tags: [],
                                 template: try TokenParser.parse(template).document)
    }

    private func match(_ typed: String) -> KeywordMatch {
        library.keywordMatcher.invalidate()
        return library.keywordMatcher.feed(typed)!
    }

    private func usage(_ id: UUID) async -> Date? { await library.snippet(id: id)?.lastUsedAt }

    private let followUp = "Hi {argument name=\"recipient\"},\n\nthanks for {date format=\"yyyy-MM-dd\"}.\n\nBest{cursor}"

    func testDirectExpansionReplacesKeywordPlacesCaretAndRecordsUsage() async throws {
        try await setUpFlow(typed: ";sig")
        let snippet = try await addSnippet(";sig", "Best{cursor} regards")
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "Dear Best regards tail")
        XCTAssertEqual(destination.selection, NSRange(location: 9, length: 0))
        let used = await usage(snippet.id)
        XCTAssertNotNil(used)
        XCTAssertFalse(result.usageRecordFailed)
        XCTAssertEqual(prompter.requests.count, 0)
    }

    func testFollowUpTemplatePromptsThenReplacesAndPlacesCaretAtMarker() async throws {
        try await setUpFlow(typed: ";fu")
        try await addSnippet(";fu", followUp)
        prompter.answers = ["recipient": "Zoë"]
        prompter.onPrompt = { [unowned self] in
            // The prompt never consumes target text.
            XCTAssertEqual(destination.text, "Dear ;fu tail")
            XCTAssertEqual(destination.writes, [])
            destination.token = FocusToken(pid: 999, element: 77)
            destination.onActivate = { [unowned self] token in destination.token = token }
        }
        let result = await coordinator.handle(match(";fu"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "Dear Hi Zoë,\n\nthanks for 2026-01-15.\n\nBest tail")
        XCTAssertEqual(prompter.requests.first?.map(\.name), ["recipient"])
        XCTAssertEqual(destination.activateCount, 1)
        XCTAssertEqual(destination.selection?.location, ("Dear Hi Zoë,\n\nthanks for 2026-01-15.\n\nBest" as NSString).length)
    }

    func testCancelledArgumentLeavesKeywordIntactAndRecordsNothing() async throws {
        try await setUpFlow(typed: ";fu")
        let snippet = try await addSnippet(";fu", followUp)
        prompter.answers = nil
        let result = await coordinator.handle(match(";fu"))
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.copyOffer)
        XCTAssertEqual(destination.text, "Dear ;fu tail")
        XCTAssertEqual(destination.writes, [])
        let used = await usage(snippet.id)
        XCTAssertNil(used)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testFieldChangedWhileThePromptWasOpenAbortsAndOffersCopy() async throws {
        try await setUpFlow(typed: ";fu")
        let snippet = try await addSnippet(";fu", followUp)
        prompter.answers = ["recipient": "Zoë"]
        prompter.onPrompt = { [unowned self] in destination.text = "Dear ;fu tail, edited" }
        let result = await coordinator.handle(match(";fu"))
        XCTAssertEqual(result.outcome, .aborted(.destinationChanged))
        XCTAssertEqual(destination.text, "Dear ;fu tail, edited")
        XCTAssertEqual(destination.writes, [])
        XCTAssertEqual(result.copyOffer?.plainText.hasPrefix("Hi Zoë,"), true)
        let used = await usage(snippet.id)
        XCTAssertNil(used)
        XCTAssertEqual(pasteboard.writeCount, 0, "Copy is offered, never done on its own")
    }

    func testFocusNotReturnedAfterThePromptAborts() async throws {
        try await setUpFlow(typed: ";fu")
        try await addSnippet(";fu", followUp)
        prompter.answers = ["recipient": "Zoë"]
        destination.canActivate = false
        let result = await coordinator.handle(match(";fu"))
        XCTAssertEqual(result.outcome, .aborted(.destinationNotReactivated))
        XCTAssertEqual(destination.writes, [])
    }

    func testSnippetDeletedAfterTheMatchFailsClosed() async throws {
        try await setUpFlow(typed: ";sig")
        let snippet = try await addSnippet(";sig", "Best")
        let found = match(";sig")
        try await library.delete(id: snippet.id)
        let result = await coordinator.handle(found)
        XCTAssertEqual(result.outcome, .failedClosed(.snippetUnavailable))
        XCTAssertEqual(destination.writes, [])
    }

    func testDecomposedTypedKeywordIsReplacedUsingTheTypedLength() async throws {
        try await setUpFlow(typed: ";gru\u{308}ß")
        try await addSnippet(";grüß", "Grüße 😀")
        let result = await coordinator.handle(match(";gru\u{308}ß"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "Dear Grüße 😀 tail")
    }

    func testUnsupportedFieldOffersCopyForADirectSnippetButNeverPromptsOrRenders() async throws {
        try await setUpFlow(typed: ";sig")
        try await addSnippet(";sig", "Best")
        try await addSnippet(";fu", followUp)
        destination.role = "AXWebArea"
        var result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.roleUnsupported))
        XCTAssertEqual(result.copyOffer?.plainText, "Best")
        result = await coordinator.handle(match(";fu"))
        XCTAssertNil(result.copyOffer)
        XCTAssertEqual(prompter.requests.count, 0)
        XCTAssertEqual(destination.writes, [])
    }

    func testPrivacyRefusalsNeverRenderOrOfferCopy() async throws {
        try await setUpFlow(typed: ";sig")
        try await addSnippet(";sig", "Best")
        let found = match(";sig")
        destination.isSecure = true
        var result = await coordinator.handle(found)
        XCTAssertEqual(result.outcome, .failedClosed(.secureField))
        XCTAssertNil(result.copyOffer)
        destination.isSecure = false
        excluded = ["com.apple.TextEdit"]
        result = await coordinator.handle(found)
        XCTAssertEqual(result.outcome, .failedClosed(.appExcluded))
        XCTAssertNil(result.copyOffer)
        excluded = []
        environment.isSecureInputActive = true
        result = await coordinator.handle(found)
        XCTAssertEqual(result.outcome, .failedClosed(.secureInput))
        XCTAssertNil(result.copyOffer)
        XCTAssertEqual(destination.writes, [])
    }
}
