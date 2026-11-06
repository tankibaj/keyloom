import AppKit
import CoreGraphics
import XCTest

final class EngineTests: XCTestCase {
    private static let prefix = "KL-FIXTURE-v1\nSTART "
    private static let suffix = " END"

    private var destination: FakeDestination!
    private var pasteboard: FakePasteboard!
    private var environment: FakeEnvironment!
    private var engine: ProbeEngine!
    private var outcomes: [Outcome] = []
    private var prompts: [PendingInsertion] = []

    /// A fixture document with `typed` already inserted before the caret.
    private func makeEngine(typed: String = ";kl", userClipboard: String? = nil, richWriter: Bool = false) {
        if richWriter {
            destination = FakeRichDestination(prefix: Self.prefix, typed: typed, suffix: Self.suffix)
        } else {
            destination = FakeDestination(prefix: Self.prefix, typed: typed, suffix: Self.suffix)
        }
        pasteboard = FakePasteboard(userClipboard: userClipboard)
        environment = FakeEnvironment()
        engine = ProbeEngine(
            destination: destination,
            pasteboard: pasteboard,
            environment: environment,
            allowedBundleIDs: ["com.apple.TextEdit"]
        )
        outcomes = []
        prompts = []
        engine.onOutcome = { [unowned self] in self.outcomes.append($0) }
        engine.onPrompt = { [unowned self] in self.prompts.append($0) }
        engine.armed = true
    }

    private func type(_ text: String, origin: InputOrigin = .physical) {
        for unit in text.utf16 { engine.handleKey(.typed(unit, origin: origin)) }
    }

    private func assertDestinationUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(destination.writes, [], file: file, line: line)
        XCTAssertEqual(pasteboard.writeCount, 0, file: file, line: line)
    }

    // MARK: Delivery

    func testImmediateKeywordReplacedWithCaretAtMarkerAfterEmoji() {
        makeEngine()
        type(";kl")
        XCTAssertEqual(outcomes, [.replaced(mode: .axPlain, verified: true, clipboard: .notTouched)])
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Hallo 👩🏽‍💻 Keyloom! END")
        XCTAssertEqual(destination.selection, NSRange(location: 41, length: 0))
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testRichDeliveryUsesTheFieldBoundWriterAndNeverTouchesTheClipboard() throws {
        makeEngine(userClipboard: "user clipboard", richWriter: true)
        engine.deliveryMode = .richField
        type(";kl")
        XCTAssertEqual(outcomes, [.replaced(mode: .richField, verified: true, clipboard: .notTouched)])
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Hallo 👩🏽‍💻 Keyloom! END")
        XCTAssertEqual(destination.selection, NSRange(location: 41, length: 0))
        XCTAssertEqual(destination.writes, ["replaceRich", "select"])
        XCTAssertEqual(try XCTUnwrap(destination as? FakeRichDestination).lastSnippet?.boldRange, NSRange(location: 14, length: 7))
        XCTAssertEqual(pasteboard.plain, "user clipboard")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testDecomposedUmlautKeywordIsReplacedUsingTypedLength() {
        makeEngine(typed: ";gru\u{308}ß")
        type(";gru\u{308}ß")
        XCTAssertEqual(outcomes, [.replaced(mode: .axPlain, verified: true, clipboard: .notTouched)])
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Grüße 😀 END")
        XCTAssertEqual(destination.selection, NSRange(location: 25, length: 0))
    }

    // MARK: Prompt, cancel and recheck

    func testPromptCancelLeavesDestinationIntact() {
        makeEngine(typed: ";hi")
        let before = destination.snapshot()
        type(";hi")
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(outcomes, [])
        engine.cancel()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertEqual(destination.snapshot(), before)
        assertDestinationUntouched()
    }

    func testPromptConfirmInsertsArgumentAndPlacesCaret() {
        makeEngine(typed: ";hi")
        type(";hi")
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.replaced(mode: .axPlain, verified: true, clipboard: .notTouched)])
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Hi Zoë! END")
        XCTAssertEqual(destination.selection, NSRange(location: 26, length: 0))
    }

    func testEmptyArgumentUsesDefaultRecipient() {
        makeEngine(typed: ";hi")
        type(";hi")
        engine.confirm(argument: "")
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Hi Alex Fixture! END")
        XCTAssertEqual(destination.selection, NSRange(location: 35, length: 0))
    }

    func testFieldChangedDuringPromptAbortsWithoutWriting() {
        makeEngine(typed: ";hi")
        type(";hi")
        destination.token = FocusToken(pid: 100, element: 2)
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.aborted(.destinationChanged)])
        assertDestinationUntouched()
    }

    func testSelectionChangedDuringPromptAbortsWithoutWriting() {
        makeEngine(typed: ";hi")
        type(";hi")
        destination.selection = NSRange(location: 2, length: 0)
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.aborted(.destinationChanged)])
        assertDestinationUntouched()
    }

    func testTextChangedDuringPromptAbortsWithoutWriting() {
        makeEngine(typed: ";hi")
        type(";hi")
        destination.text = (destination.text ?? "") + "x"
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.aborted(.destinationChanged)])
        assertDestinationUntouched()
    }

    func testDestinationNotReactivatedAbortsWithoutWriting() {
        makeEngine(typed: ";hi")
        type(";hi")
        destination.canActivate = false
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.aborted(.destinationNotReactivated)])
        assertDestinationUntouched()
    }

    func testSecureInputAfterPromptFailsClosed() {
        makeEngine(typed: ";hi")
        type(";hi")
        environment.isSecureInputActive = true
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.failedClosed(.secureInput)])
        assertDestinationUntouched()
    }

    func testDisarmingDropsPendingPrompt() {
        makeEngine(typed: ";hi")
        type(";hi")
        engine.armed = false
        XCTAssertNil(engine.pending)
    }

    // MARK: Fail closed

    func testRangeSelectionAtTriggerFailsClosedAndCopyNeedsUserAction() {
        makeEngine()
        destination.selection = NSRange(location: 21, length: 2)
        type(";kl")
        XCTAssertEqual(outcomes, [.failedClosed(.selectionNotCaret)])
        assertDestinationUntouched()
        engine.copyFallback(argument: nil)
        XCTAssertEqual(pasteboard.plain, "Hallo 👩🏽‍💻 Keyloom!")
        XCTAssertEqual(outcomes.last, .copied)
        XCTAssertEqual(destination.writes, [])
    }

    func testKeywordAbsentBeforeCaretFailsClosed() {
        makeEngine(typed: "xyz")
        type(";kl")
        XCTAssertEqual(outcomes, [.failedClosed(.keywordNotBeforeCaret)])
        assertDestinationUntouched()
    }

    func testSecureInputSuppressesTypingAndKeepsNothing() {
        makeEngine()
        environment.isSecureInputActive = true
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.counters.suppressedSecure, 3)
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
        assertDestinationUntouched()
    }

    func testInputMethodSuppressesTyping() {
        makeEngine()
        environment.isComposingInput = true
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.counters.suppressedComposing, 3)
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
        assertDestinationUntouched()
    }

    func testSecureFieldNeverReachesTheMatcher() {
        makeEngine()
        destination.isSecure = true
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
        assertDestinationUntouched()
    }

    func testNonFixtureDocumentNeverReachesTheMatcher() {
        makeEngine()
        destination.text = "ordinary text ;kl"
        destination.selection = NSRange(location: 17, length: 0)
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
        assertDestinationUntouched()
    }

    func testUnlistedApplicationNeverReachesTheMatcher() {
        makeEngine()
        destination.bundleID = "com.example.Other"
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
    }

    func testUnsupportedRoleNeverReachesTheMatcher() {
        makeEngine()
        destination.role = "AXWebArea"
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)
    }

    func testUnknownFocusInvalidatesAndNothingIsWritten() {
        makeEngine()
        destination.token = nil
        type(";kl")
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.counters.invalidations, 3)
        assertDestinationUntouched()
    }

    // MARK: Input origin and transient state

    func testOwnAndSyntheticEventsAreNotPhysicalEvidence() {
        makeEngine()
        type(";kl", origin: .ownProcess)
        type(";kl", origin: .synthetic)
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.counters.ownProcessFiltered, 3)
        XCTAssertEqual(engine.counters.syntheticIgnored, 3)
        XCTAssertEqual(engine.counters.physical, 0)
        assertDestinationUntouched()
    }

    func testSyntheticInputIsCountedSeparatelyWhenAccepted() {
        makeEngine()
        engine.acceptSynthetic = true
        type(";kl", origin: .synthetic)
        XCTAssertEqual(engine.counters.synthetic, 3)
        XCTAssertEqual(engine.counters.physical, 0)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testDisarmedProbeIgnoresInput() {
        makeEngine()
        engine.armed = false
        type(";kl")
        XCTAssertEqual(engine.counters, Counters())
        XCTAssertEqual(outcomes, [])
    }

    func testNavigationShortcutAndFocusChangeClearPartialKeyword() {
        makeEngine()
        type(";k")
        XCTAssertEqual(engine.recognizer.bufferedCount, 2)
        engine.handleKey(KeyInput(units: [0xF702], keyCode: 123, isShortcut: false, origin: .physical))
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)

        type(";k")
        engine.noteNavigation()
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)

        type(";k")
        engine.handleKey(KeyInput(units: [0x63], keyCode: 8, isShortcut: true, origin: .physical))
        XCTAssertEqual(engine.recognizer.bufferedCount, 0)

        type(";k")
        destination.token = FocusToken(pid: 100, element: 2)
        type("l")
        XCTAssertEqual(engine.recognizer.bufferedCount, 1)
        XCTAssertEqual(outcomes, [])
    }

    func testTransientInputStaysBounded() {
        makeEngine()
        type(String(repeating: "x", count: 500))
        XCTAssertEqual(engine.recognizer.bufferedCount, 32)
    }

    // MARK: Destination binding (state changing between the last check and the write)

    private static let untouchedText = "KL-FIXTURE-v1\nSTART ;kl END"

    func testSnapshotBindingRequiresSameElementAppValueAndSelection() {
        let bound = FieldSnapshot(
            token: FocusToken(pid: 1, element: 1), bundleID: "a", role: "AXTextArea", isSecure: false,
            text: "t", selection: NSRange(location: 1, length: 0)
        )
        XCTAssertTrue(bound.satisfies(bound))
        var free = bound
        free.selection = nil
        var moved = bound
        moved.selection = NSRange(location: 0, length: 0)
        XCTAssertTrue(moved.satisfies(free))
        XCTAssertFalse(moved.satisfies(bound))
        let drifted: [(inout FieldSnapshot) -> Void] = [
            { $0.token = FocusToken(pid: 1, element: 2) },
            { $0.token = FocusToken(pid: 2, element: 1) },
            { $0.bundleID = "b" },
            { $0.role = "AXTextField" },
            { $0.isSecure = true },
            { $0.text = "u" },
        ]
        for drift in drifted {
            var live = bound
            drift(&live)
            XCTAssertFalse(live.satisfies(bound))
            XCTAssertFalse(live.satisfies(free))
        }
    }

    func testDriftBeforeThePlainWriteAbortsWithoutWriting() {
        let drifts: [(String, (FakeDestination) -> Void)] = [
            ("element", { $0.token = FocusToken(pid: 100, element: 2) }),
            ("app", { $0.token = FocusToken(pid: 200, element: 1); $0.bundleID = "com.example.Other" }),
            ("selection", { $0.selection = NSRange(location: 2, length: 0) }),
            ("value", { $0.text = ($0.text ?? "") + "x" }),
        ]
        for (name, drift) in drifts {
            makeEngine()
            destination.beforeWrite = { [unowned self] in drift(self.destination) }
            type(";kl")
            XCTAssertEqual(outcomes, [.aborted(.destinationChanged)], name)
            XCTAssertEqual(destination.writes, [], name)
            XCTAssertEqual(pasteboard.writeCount, 0, name)
        }
    }

    func testCaretIsNotMovedWhenFocusLeavesAfterTheReplacement() {
        makeEngine()
        destination.beforeWrite = { [unowned self] in
            if self.destination.writes == ["replace"] { self.destination.token = FocusToken(pid: 100, element: 2) }
        }
        type(";kl")
        XCTAssertEqual(destination.writes, ["replace"])
        XCTAssertEqual(outcomes, [.replaced(mode: .axPlain, verified: false, clipboard: .notTouched)])
    }

    // MARK: Rich mode: field-bound writer only

    func testDriftBeforeTheRichWriteAbortsWithoutWriting() {
        let drifts: [(String, (FakeDestination) -> Void)] = [
            ("element", { $0.token = FocusToken(pid: 100, element: 2) }),
            ("app", { $0.token = FocusToken(pid: 200, element: 1); $0.bundleID = "com.example.Other" }),
            ("selection", { $0.selection = NSRange(location: 2, length: 0) }),
            ("value", { $0.text = ($0.text ?? "") + "x" }),
        ]
        for (name, drift) in drifts {
            makeEngine(userClipboard: "user clipboard", richWriter: true)
            engine.deliveryMode = .richField
            destination.beforeWrite = { [unowned self] in drift(self.destination) }
            type(";kl")
            XCTAssertEqual(outcomes, [.aborted(.destinationChanged)], name)
            XCTAssertEqual(destination.writes, [], name)
            XCTAssertEqual(pasteboard.writeCount, 0, name)
        }
    }

    func testCaretIsNotMovedWhenFocusLeavesAfterTheRichReplacement() {
        makeEngine(richWriter: true)
        engine.deliveryMode = .richField
        destination.beforeWrite = { [unowned self] in
            if self.destination.writes == ["replaceRich"] { self.destination.token = FocusToken(pid: 100, element: 2) }
        }
        type(";kl")
        XCTAssertEqual(destination.writes, ["replaceRich"])
        XCTAssertEqual(outcomes, [.replaced(mode: .richField, verified: false, clipboard: .notTouched)])
    }

    func testRichPromptInsertsTheArgumentThroughTheFieldBoundWriter() throws {
        makeEngine(typed: ";hi", richWriter: true)
        engine.deliveryMode = .richField
        type(";hi")
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.replaced(mode: .richField, verified: true, clipboard: .notTouched)])
        XCTAssertEqual(destination.text, "KL-FIXTURE-v1\nSTART Hi Zoë! END")
        XCTAssertEqual(try XCTUnwrap(destination as? FakeRichDestination).lastSnippet?.text, "Hi Zoë!")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    // MARK: Rich mode without a safe writer fails closed, Copy is the way out

    func testRichModeWithoutFieldBoundWriterFailsClosedBeforeAnyWrite() {
        makeEngine(userClipboard: "user clipboard")
        engine.deliveryMode = .richField
        XCTAssertFalse(engine.canInsert)
        type(";kl")
        XCTAssertEqual(outcomes, [.failedClosed(.richUnsupported)])
        assertDestinationUntouched()
        XCTAssertEqual(destination.activateCount, 0)
        XCTAssertEqual(destination.text, Self.untouchedText)
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testRichConfirmWithoutFieldBoundWriterFailsClosedBeforeActivation() {
        makeEngine(typed: ";hi", userClipboard: "user clipboard")
        engine.deliveryMode = .richField
        type(";hi")
        XCTAssertEqual(prompts.count, 1)
        engine.confirm(argument: "Zoë")
        XCTAssertEqual(outcomes, [.failedClosed(.richUnsupported)])
        assertDestinationUntouched()
        XCTAssertEqual(destination.activateCount, 0)
        XCTAssertEqual(pasteboard.plain, "user clipboard")
    }

    func testCopyAfterRichFailClosedCarriesPlainAndStyledText() throws {
        makeEngine(userClipboard: "user clipboard")
        engine.deliveryMode = .richField
        type(";kl")
        engine.copyFallback(argument: nil)
        XCTAssertEqual(outcomes, [.failedClosed(.richUnsupported), .copied])
        XCTAssertEqual(pasteboard.plain, "Hallo 👩🏽‍💻 Keyloom!")
        let styled = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(pasteboard.lastRTF), documentAttributes: nil))
        XCTAssertEqual(styled.string, "Hallo 👩🏽‍💻 Keyloom!")
        let bold = styled.attribute(.font, at: 14, effectiveRange: nil) as? NSFont
        let regular = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bold?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual(regular?.fontDescriptor.symbolicTraits.contains(.bold), false)
        XCTAssertEqual(destination.writes, [])
    }

    func testCopyCarriesTheArgumentOrItsDefaultInBothFormats() throws {
        for (argument, expected) in [("Zoë", "Hi Zoë!"), ("", "Hi Alex Fixture!")] {
            makeEngine(typed: ";hi")
            engine.deliveryMode = .richField
            type(";hi")
            engine.copyFallback(argument: argument)
            XCTAssertEqual(pasteboard.plain, expected)
            let styled = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(pasteboard.lastRTF), documentAttributes: nil))
            XCTAssertEqual(styled.string, expected)
            XCTAssertEqual(destination.writes, [])
        }
    }

    /// The real Accessibility destination has no field-bound rich writer, so the
    /// probe cannot insert styled text there. This pins that until one is proven.
    func testRealAccessibilityDestinationHasNoRichWriterAndFailsClosed() {
        let real: DestinationAccess = AXDestination()
        XCTAssertFalse(real is RichFieldWriter)
        let realEngine = ProbeEngine(
            destination: real, pasteboard: FakePasteboard(), environment: FakeEnvironment(), allowedBundleIDs: []
        )
        realEngine.deliveryMode = .richField
        XCTAssertFalse(realEngine.canInsert)
        realEngine.deliveryMode = .axPlain
        XCTAssertTrue(realEngine.canInsert)
    }
}

/// The tap's routing with its secure-input check and queue hop replaced, so the
/// order in which events reach the engine is deterministic.
final class EventTapSeamTests: XCTestCase {
    private var queue: [() -> Void] = []
    private var delivered: [TapEvent] = []
    private var secure = false
    private var outcomes: [Outcome] = []

    private func makeTap() -> EventTap {
        let tap = EventTap(
            isSecureInput: { [unowned self] in self.secure },
            enqueue: { [unowned self] in self.queue.append($0) }
        )
        tap.onEvent = { [unowned self] in self.delivered.append($0) }
        return tap
    }

    private func drain() {
        let work = queue
        queue = []
        work.forEach { $0() }
    }

    private func armedEngine() -> ProbeEngine {
        let engine = ProbeEngine(
            destination: FakeDestination(prefix: "KL-FIXTURE-v1\nSTART ", typed: ";kl", suffix: " END"),
            pasteboard: FakePasteboard(),
            environment: FakeEnvironment(),
            allowedBundleIDs: ["com.apple.TextEdit"]
        )
        engine.onOutcome = { [unowned self] in self.outcomes.append($0) }
        engine.armed = true
        return engine
    }

    func testSecureKeyIsDroppedBeforeItsUnicodeIsRead() {
        var extractions = 0
        let dropped = EventTap.route(secure: true) {
            extractions += 1
            return .typed(0x6C)
        }
        XCTAssertEqual(dropped, .secureKeySuppressed)
        XCTAssertEqual(extractions, 0)
        let kept = EventTap.route(secure: false) {
            extractions += 1
            return .typed(0x6C)
        }
        XCTAssertEqual(kept, .key(.typed(0x6C)))
        XCTAssertEqual(extractions, 1)
    }

    func testTapCallbackReportsSecureKeysWithoutForwardingThem() throws {
        let tap = makeTap()
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true))
        secure = true
        tap.handle(type: .keyDown, event: event)
        drain()
        XCTAssertEqual(delivered, [.secureKeySuppressed])
        secure = false
        tap.handle(type: .keyDown, event: event)
        drain()
        XCTAssertEqual(delivered.count, 2)
        if case .key = delivered[1] {} else { XCTFail("a plain key must be forwarded") }
    }

    func testSuppressedSecureKeyBreaksTheKeywordAcrossTheQueue() {
        let engine = armedEngine()
        let tap = makeTap()
        tap.onEvent = { engine.handle($0) }
        for event in [TapEvent.key(.typed(0x3B)), .key(.typed(0x6B)), .secureKeySuppressed, .key(.typed(0x6C))] {
            tap.forward(event)
        }
        drain()
        XCTAssertEqual(outcomes, [])
        XCTAssertEqual(engine.recognizer.bufferedCount, 1)
        XCTAssertEqual(engine.counters.suppressedSecure, 1)
    }

    func testSameKeysWithoutASuppressedGapStillMatch() {
        let engine = armedEngine()
        let tap = makeTap()
        tap.onEvent = { engine.handle($0) }
        for event in [TapEvent.key(.typed(0x3B)), .key(.typed(0x6B)), .key(.typed(0x6C))] { tap.forward(event) }
        drain()
        XCTAssertEqual(outcomes.count, 1)
    }

    func testEventsQueuedBeforeStopNeverReachTheEngine() {
        let tap = makeTap()
        tap.forward(.key(.typed(0x3B)))
        tap.forward(.key(.typed(0x6B)))
        tap.stop()
        tap.forward(.key(.typed(0x6C)))
        drain()
        XCTAssertEqual(delivered, [.key(.typed(0x6C))])
    }
}
