import XCTest
@testable import Keyloom

@MainActor
final class TargetBindingTests: XCTestCase {
    private var destination: FakeDestination!
    private var environment: FakeInputEnvironment!
    private var permissions: FakePermissions!
    private var excluded: Set<String> = []
    private var settles = 0
    private var onSettle: (() -> Void)?
    private var binder: TargetBinder!

    private func make(prefix: String = "Hello 👩🏽‍💻 ", typed: String = ";kl", suffix: String = " tail") {
        destination = FakeDestination(prefix: prefix, typed: typed, suffix: suffix)
        environment = FakeInputEnvironment()
        permissions = FakePermissions()
        excluded = []
        settles = 0
        binder = TargetBinder(destination: destination, environment: environment, permissions: permissions,
                              excludedBundleIDs: { [unowned self] in excluded },
                              settle: { [unowned self] _ in settles += 1; onSettle?() })
    }

    private func match(_ keyword: String = ";kl", typed: Int? = nil) -> KeywordMatch {
        KeywordMatch(snippetID: UUID(), keyword: keyword, typedUTF16Length: typed ?? keyword.utf16.count)
    }

    private func assertRefused(_ result: Result<BoundTarget, Refusal>, _ expected: Refusal,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let refusal) = result else { return XCTFail("expected \(expected)", file: file, line: line) }
        XCTAssertEqual(refusal, expected, file: file, line: line)
        XCTAssertEqual(destination.writes, [], file: file, line: line)
    }

    // MARK: Bind on trigger

    func testBindsKeywordRangeAfterSurrogatePairsUsingUTF16() async throws {
        make()
        let target = try await binder.bindKeyword(match()).get()
        XCTAssertEqual(target.range, NSRange(location: 14, length: 3))
        XCTAssertEqual((target.snapshot.text! as NSString).substring(with: target.range), ";kl")
    }

    func testDecomposedTypedKeywordBindsTypedLengthAgainstCanonicalKeyword() async throws {
        make(prefix: "x ", typed: ";gru\u{308}ß")
        let target = try await binder.bindKeyword(match(";grüß", typed: 6)).get()
        XCTAssertEqual(target.range.length, 6)
    }

    func testKeywordNotYetAppliedByTheAppIsWaitedFor() async throws {
        make(typed: "")
        destination.text = "Hello  tail"
        destination.selection = NSRange(location: 6, length: 0)
        onSettle = { [unowned self] in
            if settles == 2 {
                destination.text = "Hello ;kl tail"
                destination.selection = NSRange(location: 9, length: 0)
            }
        }
        let target = try await binder.bindKeyword(match()).get()
        XCTAssertEqual(target.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(settles, 2)
    }

    func testKeywordNeverAppearingFailsClosedAfterBoundedWaits() async {
        make(typed: "")
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.keywordNotBeforeCaret))
        XCTAssertEqual(settles, TargetBinder.maxSettleAttempts)
    }

    func testRefusesEveryUnsafeTarget() async {
        make()
        destination.token = nil
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.noFocus))

        make()
        excluded = ["com.apple.TextEdit"]
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.appExcluded))

        make()
        destination.isSecure = true
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.secureField))

        make()
        destination.role = "AXWebArea"
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.roleUnsupported))

        make()
        destination.text = nil
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.unreadableValue))

        make()
        destination.selection = nil
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.unreadableValue))

        make()
        destination.selection = NSRange(location: 14, length: 3)
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.selectionNotCaret))

        make()
        environment.isSecureInputActive = true
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.secureInput))

        make()
        permissions.status.accessibility = false
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.permissionRevoked))
    }

    func testCaretBeforeKeywordLengthOrDifferentTextBeforeCaretFailsClosed() async {
        make(prefix: "", typed: ";k")
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.keywordNotBeforeCaret))
        make(prefix: "ab", typed: ";kx")
        assertRefused(await binder.bindKeyword(match()), .failedClosed(.keywordNotBeforeCaret))
    }

    func testCaretBindingForPickerHasEmptyRangeAtCaret() throws {
        make()
        let target = try binder.bindCaret().get()
        XCTAssertEqual(target.range, NSRange(location: 17, length: 0))
        destination.selection = NSRange(location: 3, length: 2)
        assertRefused(binder.bindCaret(), .failedClosed(.selectionNotCaret))
    }

    // MARK: Revalidate

    private func boundTarget() async throws -> BoundTarget { try await binder.bindKeyword(match()).get() }

    func testUnchangedDestinationRevalidates() async throws {
        make()
        let target = try await boundTarget()
        let refusal = await binder.revalidate(target, reactivating: false)
        XCTAssertNil(refusal)
    }

    func testAdjacentTextChangedAfterPromptAborts() async throws {
        make()
        let target = try await boundTarget()
        destination.text = destination.text! + "!"
        let refusal = await binder.revalidate(target, reactivating: false)
        XCTAssertEqual(refusal, .aborted(.destinationChanged))
    }

    func testFieldFocusAndCaretChangesAbort() async throws {
        make()
        let target = try await boundTarget()
        destination.token = FocusToken(pid: 100, element: 2)
        var refusal = await binder.revalidate(target, reactivating: false)
        XCTAssertEqual(refusal, .aborted(.destinationChanged))
        destination.token = target.snapshot.token
        destination.selection = NSRange(location: 3, length: 0)
        refusal = await binder.revalidate(target, reactivating: false)
        XCTAssertEqual(refusal, .aborted(.destinationChanged))
        destination.selection = target.snapshot.selection
        destination.bundleID = "com.other"
        refusal = await binder.revalidate(target, reactivating: false)
        XCTAssertEqual(refusal, .aborted(.destinationChanged))
    }

    func testOwnFocusTransferForThePromptIsNotAChangeButFailureToReturnIs() async throws {
        make()
        let target = try await boundTarget()
        // The prompt took focus; reactivating the original app brings the same field back.
        destination.token = FocusToken(pid: 999, element: 77)
        destination.onActivate = { [unowned self] token in destination.token = token }
        var refusal = await binder.revalidate(target, reactivating: true)
        XCTAssertNil(refusal)
        XCTAssertEqual(destination.activateCount, 1)

        destination.token = FocusToken(pid: 999, element: 77)
        destination.canActivate = false
        refusal = await binder.revalidate(target, reactivating: true)
        XCTAssertEqual(refusal, .aborted(.destinationNotReactivated))
    }

    func testReactivationToADifferentFieldAborts() async throws {
        make()
        let target = try await boundTarget()
        destination.onActivate = { [unowned self] _ in destination.token = FocusToken(pid: 100, element: 5) }
        let refusal = await binder.revalidate(target, reactivating: true)
        XCTAssertEqual(refusal, .aborted(.destinationChanged))
    }

    func testSecureInputOrRevokedPermissionBlocksBeforeAnyActivation() async throws {
        make()
        let target = try await boundTarget()
        environment.isSecureInputActive = true
        var refusal = await binder.revalidate(target, reactivating: true)
        XCTAssertEqual(refusal, .failedClosed(.secureInput))
        environment.isSecureInputActive = false
        permissions.status.inputMonitoring = false
        refusal = await binder.revalidate(target, reactivating: true)
        XCTAssertEqual(refusal, .failedClosed(.permissionRevoked))
        XCTAssertEqual(destination.activateCount, 0)
    }

    // MARK: Element identity

    func testElementIdentityIsStableWhenFocusReturnsToAnEarlierElement() {
        var cache = ElementIdentityCache<String>(capacity: 4, same: ==)
        let first = cache.id(for: "field-a")
        XCTAssertNotEqual(cache.id(for: "field-b"), first)
        XCTAssertEqual(cache.id(for: "field-a"), first)
    }

    func testElementIdentityCacheIsBoundedAndNeverReusesAnEvictedID() {
        var cache = ElementIdentityCache<Int>(capacity: 2, same: ==)
        let first = cache.id(for: 1)
        _ = cache.id(for: 2)
        _ = cache.id(for: 3)
        XCTAssertNotEqual(cache.id(for: 1), first, "an evicted element gets a fresh id, so an old token can never match it")
    }
}
