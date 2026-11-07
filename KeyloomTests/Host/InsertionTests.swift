import XCTest
@testable import Keyloom

@MainActor
class InsertionTestCase: XCTestCase {
    var destination: FakeDestination!
    var environment: FakeInputEnvironment!
    var permissions: FakePermissions!
    var pasteboard: FakePasteboard!
    var keys: FakePasteKeys!
    var engine: InsertionEngine!
    var settles = 0
    var onSettle: (() -> Void)?

    func make(prefix: String = "Dear ", typed: String = ";kl", suffix: String = " tail", clipboard: String? = "user clipboard") {
        destination = FakeDestination(prefix: prefix, typed: typed, suffix: suffix)
        environment = FakeInputEnvironment()
        permissions = FakePermissions()
        pasteboard = FakePasteboard(userClipboard: clipboard)
        keys = FakePasteKeys()
        settles = 0
        onSettle = nil
        let settle: (TimeInterval) async -> Void = { [unowned self] _ in settles += 1; onSettle?() }
        let binder = TargetBinder(destination: destination, environment: environment, permissions: permissions,
                                  excludedBundleIDs: { [] }, settle: settle)
        engine = InsertionEngine(binder: binder, destination: destination, permissions: permissions,
                                 pasteboard: pasteboard, keys: keys, settle: settle)
    }

    func bound(_ keyword: String = ";kl") async throws -> BoundTarget {
        let match = KeywordMatch(snippetID: UUID(), keyword: keyword, typedUTF16Length: keyword.utf16.count)
        return try await engine.binder.bindKeyword(match).get()
    }

    func rendered(_ text: String, cursor: Int? = nil, boldRange: Range<Int>? = nil) -> RenderedSnippet {
        let units = Array(text.utf16)
        var segments: [StyledSegment] = []
        if let boldRange {
            let part = { (range: Range<Int>) in String(decoding: units[range], as: UTF16.self) }
            segments = [StyledSegment(text: part(0..<boldRange.lowerBound), style: []),
                        StyledSegment(text: part(boldRange), style: .bold),
                        StyledSegment(text: part(boldRange.upperBound..<units.count), style: [])]
        } else {
            segments = [StyledSegment(text: text, style: [])]
        }
        return RenderedSnippet(segments: segments, plainText: text, cursorOffset: cursor)
    }

    func assertUntouched(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(destination.text, expected, file: file, line: line)
        XCTAssertEqual(destination.writes, [], file: file, line: line)
        XCTAssertEqual(pasteboard.writeCount, 0, file: file, line: line)
    }
}

final class InsertionTests: InsertionTestCase {
    func testPlainReplacementPlacesCaretAtMarkerAndNeverTouchesClipboard() async throws {
        make(prefix: "Hallo 👩🏽‍💻 ")
        let target = try await bound()
        let outcome = await engine.insert(rendered("Grüße 😀 end", cursor: 5), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "Hallo 👩🏽‍💻 Grüße 😀 end tail")
        XCTAssertEqual(destination.selection, NSRange(location: 14 + 5, length: 0))
        XCTAssertEqual(destination.writes, ["replace", "select"])
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testMixedScriptsPlaceCaretInUTF16Units() async throws {
        make(prefix: "שלום ")
        let target = try await bound()
        let text = "日本語 مرحبا 👨‍👩‍👧 x"
        let caret = ("日本語 مرحبا 👨‍👩‍👧" as NSString).length
        _ = await engine.insert(rendered(text, cursor: caret), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(destination.selection, NSRange(location: 5 + caret, length: 0))
        XCTAssertEqual(destination.text, "שלום " + text + " tail")
    }

    func testWithoutMarkerCaretStaysWhereTheAppLeftIt() async throws {
        make()
        let target = try await bound()
        let outcome = await engine.insert(rendered("Hi"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.writes, ["replace"])
        XCTAssertEqual(destination.selection, NSRange(location: 7, length: 0))
    }

    func testEmptyRangeInsertsAtCaretWithoutRemovingText() async throws {
        make(prefix: "ab", typed: "", suffix: "cd")
        let target = try engine.binder.bindCaret().get()
        let outcome = await engine.insert(rendered("X"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .replaced(mode: .plain, verified: true, clipboard: .notTouched))
        XCTAssertEqual(destination.text, "abXcd")
    }

    func testAdjacentTextChangedBeforeTheWriteAbortsLeavingTextIntact() async throws {
        make()
        let target = try await bound()
        destination.beforeWrite = { [unowned self] in destination.text = "Dear ;kl tail!" }
        let outcome = await engine.insert(rendered("Hi"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .aborted(.destinationChanged))
        XCTAssertEqual(destination.text, "Dear ;kl tail!")
        XCTAssertEqual(destination.writes, [])
    }

    func testFocusMovedBeforeTheWriteAborts() async throws {
        make()
        let target = try await bound()
        destination.beforeWrite = { [unowned self] in destination.token = FocusToken(pid: 100, element: 9) }
        let outcome = await engine.insert(rendered("Hi"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .aborted(.destinationChanged))
        XCTAssertEqual(destination.text, "Dear ;kl tail")
    }

    func testCancelledBeforeTheWriteAbortsWithoutWriting() async throws {
        make()
        let target = try await bound()
        destination.onActivate = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let outcome = await Task { [engine = engine!, target] in
            await engine.insert(self.rendered("Hi"), into: target, route: .plain, reactivating: true)
        }.value
        XCTAssertEqual(outcome, .aborted(.cancelled))
        assertUntouched("Dear ;kl tail")
    }

    func testRevokedPermissionAndSecureInputWriteNothing() async throws {
        make()
        let target = try await bound()
        permissions.status.accessibility = false
        var outcome = await engine.insert(rendered("Hi"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .failedClosed(.permissionRevoked))
        permissions.status.accessibility = true
        environment.isSecureInputActive = true
        outcome = await engine.insert(rendered("Hi"), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .failedClosed(.secureInput))
        assertUntouched("Dear ;kl tail")
    }

    func testCaretPlacementRefusedAfterTheUserTypedStillReportsUnverified() async throws {
        make()
        let target = try await bound()
        var writeChecks = 0
        destination.beforeWrite = { [unowned self] in
            writeChecks += 1
            if writeChecks == 2 { destination.text = (destination.text ?? "") + "!" }
        }
        let outcome = await engine.insert(rendered("Hi", cursor: 1), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(outcome, .replaced(mode: .plain, verified: false, clipboard: .notTouched))
    }

    func testStyledSnippetInsertsItsPlainTextOnTheAutomaticRoute() async throws {
        make()
        let target = try await bound()
        _ = await engine.insert(rendered("Hello Bob", boldRange: 6..<9), into: target, route: .plain, reactivating: false)
        XCTAssertEqual(destination.text, "Dear Hello Bob tail")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }
}
