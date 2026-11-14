import XCTest
@testable import Keyloom

final class UTF16OffsetTests: XCTestCase {
    private let combining = "e\u{301}x"                       // 3 scalars, 3 UTF-16 units, 2 graphemes
    private let surrogate = "a\u{1F600}b"                      // 3 scalars, 4 UTF-16 units
    private let zwj = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // 5 scalars, 8 UTF-16 units, 1 grapheme

    func testEmptyStringAcceptsOnlyZero() throws {
        XCTAssertEqual(try "".validatedScalarIndex(utf16Offset: 0), "".startIndex)
        XCTAssertThrowsError(try "".validatedScalarIndex(utf16Offset: 1)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: 1, length: 0))
        }
    }

    func testOffsetsBetweenBaseAndCombiningMarkAreScalarBoundaries() throws {
        for offset in 0...3 {
            XCTAssertNoThrow(try combining.validatedScalarIndex(utf16Offset: offset), "offset \(offset)")
        }
    }

    func testOffsetInsideSurrogatePairIsRejected() throws {
        XCTAssertNoThrow(try surrogate.validatedScalarIndex(utf16Offset: 1))
        XCTAssertNoThrow(try surrogate.validatedScalarIndex(utf16Offset: 3))
        XCTAssertThrowsError(try surrogate.validatedScalarIndex(utf16Offset: 2)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetNotOnScalarBoundary(offset: 2))
        }
    }

    func testZWJSequenceOnlyAllowsScalarBoundaries() {
        let valid: Set<Int> = [0, 2, 3, 5, 6, 8]
        for offset in 0...8 {
            let accepted = (try? zwj.validatedScalarIndex(utf16Offset: offset)) != nil
            XCTAssertEqual(accepted, valid.contains(offset), "offset \(offset)")
        }
    }

    func testOutOfBoundsOffsetsAreRejected() {
        XCTAssertThrowsError(try surrogate.validatedScalarIndex(utf16Offset: -1)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: -1, length: 4))
        }
        XCTAssertThrowsError(try surrogate.validatedScalarIndex(utf16Offset: 5)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: 5, length: 4))
        }
    }

    func testConvertsBetweenUTF16AndScalarOffsets() throws {
        XCTAssertEqual(try surrogate.scalarOffset(forUTF16Offset: 3), 2)
        XCTAssertEqual(try surrogate.utf16Offset(forScalarOffset: 2), 3)
        XCTAssertEqual(try zwj.scalarOffset(forUTF16Offset: 8), 5)
        XCTAssertEqual(try zwj.utf16Offset(forScalarOffset: 3), 5)
        XCTAssertThrowsError(try surrogate.scalarOffset(forUTF16Offset: 2))
        XCTAssertThrowsError(try surrogate.utf16Offset(forScalarOffset: 4)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: 4, length: 3))
        }
    }

    func testConvertsBetweenStringIndexAndUTF16Offset() throws {
        let index = try surrogate.validatedScalarIndex(utf16Offset: 3)
        XCTAssertEqual(surrogate[index...], "b")
        XCTAssertEqual(surrogate.utf16Offset(of: index), 3)
    }

    func testCursorInsideScalarIsATypedError() throws {
        XCTAssertEqual(try surrogate.validatedCursor(utf16Offset: 3), 3)
        XCTAssertThrowsError(try surrogate.validatedCursor(utf16Offset: 2)) {
            XCTAssertEqual($0 as? KeyloomError, .cursorInsideScalar(offset: 2))
        }
        XCTAssertThrowsError(try surrogate.validatedCursor(utf16Offset: 9)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetOutOfBounds(offset: 9, length: 4))
        }
    }

    func testValidatedRangeRoundTripsToStringRange() throws {
        let range = try ValidatedUTF16Range(start: 1, end: 3, in: surrogate)
        XCTAssertEqual(range.length, 2)
        XCTAssertEqual(surrogate[try range.stringRange(in: surrogate)], "\u{1F600}")

        let fromIndices = try ValidatedUTF16Range(surrogate.index(after: surrogate.startIndex)..<surrogate.endIndex, in: surrogate)
        XCTAssertEqual(fromIndices.start, 1)
        XCTAssertEqual(fromIndices.end, 4)
    }

    func testValidatedRangeRejectsBadBoundsAndSplitScalars() {
        XCTAssertThrowsError(try ValidatedUTF16Range(start: 3, end: 1, in: surrogate)) {
            XCTAssertEqual($0 as? KeyloomError, .invalidRange(start: 3, end: 1))
        }
        XCTAssertThrowsError(try ValidatedUTF16Range(start: 0, end: 2, in: surrogate)) {
            XCTAssertEqual($0 as? KeyloomError, .offsetNotOnScalarBoundary(offset: 2))
        }
        XCTAssertThrowsError(try ValidatedUTF16Range(start: 0, end: 5, in: surrogate))
    }

    func testValidatedRangeIsRevalidatedAgainstAnotherString() throws {
        let range = try ValidatedUTF16Range(start: 0, end: 1, in: "ab")
        XCTAssertThrowsError(try range.stringRange(in: "\u{1F600}x")) {
            XCTAssertEqual($0 as? KeyloomError, .offsetNotOnScalarBoundary(offset: 1))
        }
    }
}
