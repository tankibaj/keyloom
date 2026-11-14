/// Offsets cross the core/AppKit boundary as UTF-16 code units, which must sit on Unicode scalar
/// boundaries. Boundaries inside a grapheme cluster (combining marks, ZWJ joins) are valid; only a
/// position between the two halves of a surrogate pair is not.
extension String {
    /// The index at `utf16Offset`, or a typed error when out of bounds or inside a surrogate pair.
    func validatedScalarIndex(utf16Offset offset: Int) throws -> String.Index {
        let length = utf16.count
        guard offset >= 0, offset <= length else {
            throw KeyloomError.offsetOutOfBounds(offset: offset, length: length)
        }
        let index = utf16.index(utf16.startIndex, offsetBy: offset)
        if index < utf16.endIndex, UTF16.isTrailSurrogate(utf16[index]) {
            throw KeyloomError.offsetNotOnScalarBoundary(offset: offset)
        }
        return index
    }

    func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index)
    }

    func scalarOffset(forUTF16Offset offset: Int) throws -> Int {
        let index = try validatedScalarIndex(utf16Offset: offset)
        return unicodeScalars.distance(from: unicodeScalars.startIndex, to: index)
    }

    func utf16Offset(forScalarOffset offset: Int) throws -> Int {
        let length = unicodeScalars.count
        guard offset >= 0, offset <= length else {
            throw KeyloomError.offsetOutOfBounds(offset: offset, length: length)
        }
        return utf16Offset(of: unicodeScalars.index(unicodeScalars.startIndex, offsetBy: offset))
    }

    /// Validates a caret position; a split scalar reports `cursorInsideScalar`.
    func validatedCursor(utf16Offset offset: Int) throws -> Int {
        do {
            _ = try validatedScalarIndex(utf16Offset: offset)
            return offset
        } catch KeyloomError.offsetNotOnScalarBoundary(let bad) {
            throw KeyloomError.cursorInsideScalar(offset: bad)
        }
    }
}

/// A UTF-16 range proven to lie within a string and on scalar boundaries.
struct ValidatedUTF16Range: Sendable, Hashable {
    let start: Int
    let end: Int
    var length: Int { end - start }

    init(start: Int, end: Int, in text: String) throws {
        guard start <= end else { throw KeyloomError.invalidRange(start: start, end: end) }
        _ = try text.validatedScalarIndex(utf16Offset: start)
        _ = try text.validatedScalarIndex(utf16Offset: end)
        self.start = start
        self.end = end
    }

    init(_ range: Range<String.Index>, in text: String) throws {
        try self.init(start: text.utf16Offset(of: range.lowerBound), end: text.utf16Offset(of: range.upperBound), in: text)
    }

    /// Re-validates against `text`, so a range made for another string cannot split a scalar here.
    func stringRange(in text: String) throws -> Range<String.Index> {
        try text.validatedScalarIndex(utf16Offset: start)..<text.validatedScalarIndex(utf16Offset: end)
    }
}
