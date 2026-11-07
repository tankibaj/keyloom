import XCTest
@testable import Keyloom

/// Typing over a keyword in fields Accessibility cannot drive: Delete per character, one paste, clipboard given back.
@MainActor
final class KeystrokeInsertionTests: StoreTestCase {
    private var library: SnippetLibrary!
    private var destination: FakeDestination!
    private var environment: FakeInputEnvironment!
    private var workspace: FakeWorkspace!
    private var permissions: FakePermissions!
    private var pasteboard: FakePasteboard!
    private var keys: FakePasteKeys!
    private var excluded: Set<String> = []
    private var coordinator: ExpansionCoordinator!
    private var inserter: KeystrokeInserter!

    private func setUpFlow(typed: String = ";sig") async throws {
        let url = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        library = try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                           now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
        destination = FakeDestination(prefix: "Dear ", typed: typed, suffix: "")
        environment = FakeInputEnvironment()
        workspace = FakeWorkspace()
        permissions = FakePermissions()
        pasteboard = FakePasteboard(userClipboard: "user clipboard")
        keys = FakePasteKeys()
        excluded = []
        let settle: (TimeInterval) async -> Void = { _ in }
        let binder = TargetBinder(destination: destination, environment: environment, permissions: permissions,
                                  excludedBundleIDs: { [unowned self] in excluded }, settle: settle)
        let engine = InsertionEngine(binder: binder, destination: destination, permissions: permissions, pasteboard: pasteboard,
                                     keys: keys, settle: settle)
        inserter = KeystrokeInserter(destination: destination, environment: environment, workspace: workspace,
                                     permissions: permissions, pasteboard: pasteboard, keys: keys,
                                     excludedBundleIDs: { [unowned self] in excluded }, settle: settle)
        let prompter = FakePrompter()
        coordinator = ExpansionCoordinator(library: library, binder: binder, engine: engine, prompter: prompter, keystrokes: inserter,
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

    func testUnreadableFieldIsTypedOverWithDeletesAndOnePasteThenTheClipboardIsGivenBack() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best regards")
        destination.token = nil
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: false, clipboard: .restored))
        XCTAssertEqual(keys.posted, ["backspaces:4", "paste"])
        XCTAssertEqual(pasteboard.plain, "user clipboard")
        XCTAssertEqual(destination.writes, [])
    }

    func testAnyRoleIsTypedOverExceptListsAndOtherNonTextControls() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.role = "AXWebArea"
        var result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: false, clipboard: .restored))
        destination.role = "AXList"
        result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.roleUnsupported))
        XCTAssertEqual(keys.posted, ["backspaces:4", "paste"], "Nothing is typed into a list")
    }

    func testAReadableFieldThatDisagreesWithTheMatchIsNeverTypedOver() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.selection = NSRange(location: 0, length: 0)
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.keywordNotBeforeCaret))
        XCTAssertEqual(keys.posted, [])
    }

    func testAFailedPostSendsNoDeleteAndGivesTheClipboardBack() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        keys.succeeds = false
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .aborted(.writeFailed))
        XCTAssertEqual(keys.posted, [], "Deletes and paste are posted together or not at all")
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testKeystrokesGoToTheFrontmostProcessAndTheBorrowedClipboardIsMarkedTransient() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        workspace.frontmostPID = 4242
        pasteboard.onWrite = { [unowned self] in XCTAssertTrue(pasteboard.lastWriteWasTransient) }
        _ = await coordinator.handle(match(";sig"))
        XCTAssertEqual(keys.targets, [4242])
        XCTAssertEqual(pasteboard.writeCount, 1)
    }

    func testSwitchOffNeverTypesOverButFinderIsNeverTypedOverEither() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        inserter.isEnabled = false
        var result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.noFocus))
        inserter.isEnabled = true
        workspace.frontmostBundleID = "com.apple.finder"
        result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.noFocus))
        XCTAssertEqual(keys.posted, [])
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testTypingOverNeedsTheFieldUnchangedOnTwoReadsAndALateWriteStopsIt() async throws {
        try await setUpFlow()
        let target = BoundTarget(snapshot: destination.snapshot()!, range: NSRange(location: 5, length: 4))
        var settles = 0
        func inserter(onSettle: @escaping () -> Void) -> KeystrokeInserter {
            KeystrokeInserter(destination: destination, environment: environment, workspace: workspace, permissions: permissions,
                              pasteboard: pasteboard, keys: keys, excludedBundleIDs: { [] }, settle: { _ in settles += 1; onSettle() })
        }
        var accepted = await inserter(onSettle: {}).accepts(afterFailedWriteTo: target)
        XCTAssertTrue(accepted)
        XCTAssertEqual(settles, 2)
        settles = 0
        accepted = await inserter(onSettle: { [unowned self] in if settles == 2 { destination.text = "Dear Best" } })
            .accepts(afterFailedWriteTo: target)
        XCTAssertFalse(accepted, "The app applied the write after the first read")
    }

    func testCursorMarkerMovesTheCaretBackOverTheTextAfterIt() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best{cursor} regards")
        destination.token = nil
        _ = await coordinator.handle(match(";sig"))
        XCTAssertEqual(keys.posted, ["backspaces:4", "paste", "left:8"])
    }

    func testAnAppThatIgnoresTheAccessibilityWriteIsTypedOverWhenTheFieldIsUnchanged() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.ignoresReplace = true
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: false, clipboard: .restored))
        XCTAssertEqual(keys.posted, ["backspaces:4", "paste"])
    }

    func testAnythingTypedClickedOrSwitchedSinceTheMatchStopsBeforeTheFirstKeystroke() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        let result = await coordinator.handle(match(";sig"), interrupted: { true })
        XCTAssertEqual(result.outcome, .aborted(.destinationChanged))
        XCTAssertEqual(keys.posted, [])
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testAnotherAppComingToTheFrontStopsBeforeTheFirstKeystroke() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        pasteboard.onWrite = { [unowned self] in workspace.frontmostPID = 200 }
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .aborted(.destinationChanged))
        XCTAssertEqual(keys.posted, [])
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testSecureInputExcludedAppAndRevokedAccessibilityNeverGetKeystrokes() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        environment.isSecureInputActive = true
        var result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.secureInput))
        environment.isSecureInputActive = false
        excluded = ["com.apple.TextEdit"]
        result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.appExcluded))
        excluded = []
        permissions.status.accessibility = false
        result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.permissionRevoked))
        XCTAssertEqual(keys.posted, [])
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testSecureFieldIsNeverTypedOver() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.isSecure = true
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .failedClosed(.secureField))
        XCTAssertEqual(keys.posted, [])
    }

    func testSnippetThatNeedsAnswersIsNotTypedOver() async throws {
        try await setUpFlow()
        try await addSnippet(";fu", "Hi {argument name=\"recipient\"}")
        destination.token = nil
        let result = await coordinator.handle(match(";fu"))
        XCTAssertEqual(result.outcome, .failedClosed(.noFocus))
        XCTAssertEqual(keys.posted, [])
    }

    func testAnotherAppCopyingMeanwhileKeepsItsClipboard() async throws {
        try await setUpFlow()
        try await addSnippet(";sig", "Best")
        destination.token = nil
        keys.onPost = { [unowned self] in pasteboard.otherAppCopies("theirs") }
        let result = await coordinator.handle(match(";sig"))
        XCTAssertEqual(result.outcome, .replaced(mode: .plain, verified: false, clipboard: .restoreSkippedOwnershipLost))
        XCTAssertEqual(pasteboard.plain, "theirs")
    }
}
