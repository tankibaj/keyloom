import XCTest
@testable import Keyloom

/// Secure input: the event text is never read, and what was typed around the gap never combines.
@MainActor
final class HostSecureInputTests: XCTestCase {
    private let environment = FakeInputEnvironment()
    private var host: InputHost!
    private var matches: [KeywordMatch] = []
    private var matcher: KeywordMatcher!

    override func setUp() async throws {
        let snippet = Snippet(name: "n", icon: .emoji("x"), keyword: ";kl", template: Document(paragraphs: []),
                              createdAt: Date(timeIntervalSince1970: 0))
        matcher = KeywordMatcher(store: KeywordIndexStore(KeywordIndex(snippets: [snippet])))
        host = InputHost(matcher: matcher, environment: environment, workspace: FakeWorkspace())
        host.isEnabled = true
        matches = []
        host.onMatch = { [unowned self] in matches.append($0) }
    }

    private func press(_ unit: UInt16, read: ReadFlag? = nil) {
        host.handleKeyDown(origin: .physical) {
            read?.set()
            return KeyContent(units: [unit], keyCode: 0, hasCommandOrControl: false)
        }
    }

    func testSecureInputDropsTheEventBeforeItsTextIsRead() {
        environment.isSecureInputActive = true
        let read = ReadFlag()
        for unit in ";kl".utf16 { press(unit, read: read) }
        XCTAssertFalse(read.value)
        XCTAssertEqual(host.counters.suppressedSecure, 3)
        XCTAssertEqual(matcher.bufferedScalarCount, 0)
        XCTAssertTrue(matches.isEmpty)
    }

    func testTextTypedBeforeAndAfterASecureGapNeverCombines() {
        press(0x3B)
        press(0x6B)
        environment.isSecureInputActive = true
        press(0x6C)
        environment.isSecureInputActive = false
        press(0x6C)
        XCTAssertTrue(matches.isEmpty)
    }
}
