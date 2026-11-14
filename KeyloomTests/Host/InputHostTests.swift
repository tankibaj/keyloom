import XCTest
@testable import Keyloom

@MainActor
final class InputHostTests: XCTestCase {
    private let snippetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var matcher: KeywordMatcher!
    private var environment: FakeInputEnvironment!
    private var workspace: FakeWorkspace!
    private var host: InputHost!
    private var matches: [KeywordMatch] = []

    override func setUp() async throws {
        let snippets = [";kl", ";grüß"].map {
            Snippet(id: $0 == ";kl" ? snippetID : UUID(), name: $0, icon: .emoji("x"), keyword: $0,
                    template: Document(paragraphs: []), createdAt: Date(timeIntervalSince1970: 0))
        }
        matcher = KeywordMatcher(store: KeywordIndexStore(KeywordIndex(snippets: snippets)))
        environment = FakeInputEnvironment()
        workspace = FakeWorkspace()
        host = InputHost(matcher: matcher, environment: environment, workspace: workspace)
        host.isEnabled = true
        matches = []
        host.onMatch = { [unowned self] in matches.append($0) }
    }

    private func key(_ text: String, keyCode: UInt16 = 0, command: Bool = false, origin: InputOrigin = .physical,
                     read: ReadFlag? = nil) {
        host.handleKeyDown(origin: origin) {
            read?.set()
            return KeyContent(units: Array(text.utf16), keyCode: keyCode, hasCommandOrControl: command)
        }
    }

    private func type(_ text: String) {
        for unit in text.utf16 { key(String(utf16CodeUnits: [unit], count: 1)) }
    }

    func testTypedKeywordFiresMatchWithTypedLength() {
        type(";kl")
        XCTAssertEqual(matches.map(\.snippetID), [snippetID])
        XCTAssertEqual(matches.first?.typedUTF16Length, 3)
    }

    func testDecomposedUmlautKeywordMatchesWithTypedLength() {
        type(";gru\u{308}ß")
        XCTAssertEqual(matches.first?.typedUTF16Length, 6)
    }

    func testOwnInsertionEventsAreIgnoredAndNeverRead() {
        let read = ReadFlag()
        type(";k")
        key("l", origin: .ownProcess, read: read)
        XCTAssertFalse(read.value)
        XCTAssertEqual(host.counters.ownEventsIgnored, 1)
        type("l")
        XCTAssertEqual(matches.count, 1, "own events neither match nor break the buffer")
    }

    func testSyntheticEventsFromOtherProcessesAreIgnoredAndInvalidate() {
        type(";k")
        key("x", origin: .synthetic)
        type("l")
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(host.counters.syntheticIgnored, 1)
    }

    func testPausedHostDropsInputUnreadAndClearsBuffer() {
        type(";k")
        host.isPaused = true
        let read = ReadFlag()
        key("l", read: read)
        host.isPaused = false
        type("l")
        XCTAssertFalse(read.value)
        XCTAssertTrue(matches.isEmpty)
    }

    func testDisabledHostWithoutPermissionsDropsInputUnread() {
        host.isEnabled = false
        let read = ReadFlag()
        key(";", read: read)
        XCTAssertFalse(read.value)
    }

    func testExcludedFrontmostAppDropsInputUnread() {
        host.excludedBundleIDs = ["com.apple.TextEdit"]
        let read = ReadFlag()
        key(";", read: read)
        type(";kl")
        XCTAssertFalse(read.value)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(host.counters.suppressedExcluded, 4)
    }

    func testUnknownFrontmostAppFailsClosed() {
        workspace.frontmostBundleID = nil
        type(";kl")
        XCTAssertTrue(matches.isEmpty)
    }

    func testComposingInputIsDroppedUnreadAndInvalidates() {
        type(";k")
        environment.isComposingInput = true
        let read = ReadFlag()
        key("l", read: read)
        environment.isComposingInput = false
        type("l")
        XCTAssertFalse(read.value)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(host.counters.suppressedComposing, 1)
    }

    func testInvalidatingKeysBreakTheKeyword() {
        let breakers: [(String, UInt16)] = [("", 123), ("", 51), ("\u{7F}", 51), ("\r", 36), ("\u{F702}", 123), ("", 0)]
        for (text, code) in breakers {
            type(";k")
            key(text, keyCode: code)
            type("l")
        }
        XCTAssertTrue(matches.isEmpty)
    }

    func testCommandOrControlShortcutBreaksTheKeyword() {
        type(";k")
        key("a", command: true)
        type("l")
        XCTAssertTrue(matches.isEmpty)
    }

    func testOptionTypedPrintableCharacterIsTypingNotAShortcut() {
        key("@")
        XCTAssertEqual(matcher.bufferedScalarCount, 1)
    }

    func testNavigationAndFocusChangeInvalidate() {
        type(";k")
        host.invalidate()
        type("l")
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(host.counters.invalidations, 1)
    }

    func testSuspendedWhileProcessingDropsInputAndInvalidates() {
        type(";k")
        host.isSuspended = true
        type("l")
        host.isSuspended = false
        type("l")
        XCTAssertTrue(matches.isEmpty)
    }

    func testBufferStaysBounded() {
        type(String(repeating: "a", count: 500))
        XCTAssertLessThanOrEqual(matcher.bufferedScalarCount, matcher.bufferCapacity)
    }
}
