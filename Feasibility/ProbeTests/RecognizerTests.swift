import XCTest

final class RecognizerTests: XCTestCase {
    private func push(_ recognizer: Recognizer, _ text: String) -> KeywordMatch? {
        for unit in text.utf16 {
            if let match = recognizer.push([unit]) { return match }
        }
        return nil
    }

    func testFixtureKeywordsMatchImmediately() {
        XCTAssertEqual(push(Recognizer(), ";kl"), KeywordMatch(keywordLength: 3, fixtureIndex: 0, hasArgument: false))
        XCTAssertEqual(push(Recognizer(), ";hi"), KeywordMatch(keywordLength: 3, fixtureIndex: 2, hasArgument: true))
    }

    func testKeywordFiresOnItsLastUnitAndClearsTheBuffer() {
        let recognizer = Recognizer()
        XCTAssertNil(push(recognizer, ";k"))
        XCTAssertEqual(recognizer.push([UInt16(0x6C)])?.fixtureIndex, 0)
        XCTAssertEqual(recognizer.bufferedCount, 0)
    }

    func testRecognizesInsideLongerTypingAndWholeSliceAtOnce() {
        XCTAssertEqual(push(Recognizer(), "abc ;kl")?.keywordLength, 3)
        XCTAssertEqual(Recognizer().push(Array(";hi".utf16))?.fixtureIndex, 2)
    }

    func testComposedAndDecomposedUmlautMatchWithTypedLength() {
        XCTAssertEqual(push(Recognizer(), ";grüß"), KeywordMatch(keywordLength: 5, fixtureIndex: 1, hasArgument: false))
        XCTAssertEqual(push(Recognizer(), ";gru\u{308}ß"), KeywordMatch(keywordLength: 6, fixtureIndex: 1, hasArgument: false))
    }

    func testCombiningMarkAfterOtherLetterIsKeptAsTypedInput() {
        let recognizer = Recognizer()
        _ = push(recognizer, "x\u{308}")
        XCTAssertEqual(recognizer.bufferedCount, 2)
    }

    func testBufferIsBoundedAndResetClearsIt() {
        let recognizer = Recognizer()
        for _ in 0..<10 { _ = recognizer.push(Array(repeating: UInt16(0x78), count: 1000)) }
        XCTAssertEqual(recognizer.bufferedCount, 32)
        recognizer.reset()
        XCTAssertEqual(recognizer.bufferedCount, 0)
    }

    func testResetDiscardsPartialKeyword() {
        let recognizer = Recognizer()
        _ = push(recognizer, ";k")
        recognizer.reset()
        XCTAssertNil(recognizer.push([UInt16(0x6C)]))
    }

    func testRenderedCursorIsUTF16OffsetAfterEmojiWithBoldSpan() throws {
        let rendered = try XCTUnwrap(Recognizer.render(fixtureIndex: 0, argument: nil))
        XCTAssertEqual(rendered.text, "Hallo 👩🏽‍💻 Keyloom!")
        XCTAssertEqual((rendered.text as NSString).length, 22)
        XCTAssertEqual(rendered.cursor, 21)
        XCTAssertEqual(rendered.boldRange, NSRange(location: 14, length: 7))
    }

    func testArgumentDefaultsWhenEmptyAndOverridesWhenGiven() throws {
        XCTAssertEqual(Recognizer.render(fixtureIndex: 2, argument: nil)?.text, "Hi Alex Fixture!")
        XCTAssertEqual(Recognizer.render(fixtureIndex: 2, argument: "")?.text, "Hi Alex Fixture!")
        XCTAssertEqual(Recognizer.render(fixtureIndex: 2, argument: nil)?.cursor, 15)
        let custom = try XCTUnwrap(Recognizer.render(fixtureIndex: 2, argument: "Zoë"))
        XCTAssertEqual(custom.text, "Hi Zoë!")
        XCTAssertEqual(custom.cursor, 6)
        XCTAssertNil(custom.boldRange)
    }

    func testKeywordLookupAndUnknownFixtureIsRejected() {
        XCTAssertEqual(Recognizer.keyword(fixtureIndex: 1), ";grüß")
        XCTAssertNil(Recognizer.keyword(fixtureIndex: 99))
        XCTAssertNil(Recognizer.render(fixtureIndex: 99, argument: nil))
        XCTAssertNil(Recognizer.render(fixtureIndex: -1, argument: nil))
    }

    func testRichPayloadCarriesTheBoldSpan() throws {
        let rendered = try XCTUnwrap(Recognizer.render(fixtureIndex: 0, argument: nil))
        let rtf = try XCTUnwrap(rendered.rtfData())
        let attributed = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        let bold = try XCTUnwrap(attributed.attribute(.font, at: 14, effectiveRange: nil) as? NSFont)
        let plain = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: plain).contains(.boldFontMask))
    }
}
