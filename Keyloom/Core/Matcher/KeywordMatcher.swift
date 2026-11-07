import Foundation
import os

/// Bounded, immediate keyword recognizer. No AppKit, database or cloud access: safe to call from a
/// keyboard callback.
///
/// - Recognition is immediate: a keyword matches on its final scalar, with no delimiter. The first keyword
///   to complete wins, so with `::a` and `::ab` typing `::a` expands and `::ab` is unreachable.
///   `KeywordConflicts` reports such overlaps.
/// - The only state is the most recent input, capped at the longest keyword (`bufferCapacity`). It lives in
///   memory only, is never persisted or logged, and is cleared after every match and by `invalidate()`.
/// - Input is a stream of Unicode scalars. A combining mark that composes with the previous scalar
///   (`u` + U+0308 -> `ü`) is folded into it, so decomposed and precomposed typing both match an NFC
///   keyword. Emoji, skin tones and ZWJ sequences are plain scalar runs. Because matching is immediate, a
///   keyword ending in a base letter fires before a following mark arrives, and a keyword may match the
///   tail of a longer grapheme cluster (`💻` inside `👩‍💻`).
/// - The caller calls `invalidate()` on focus change, invalidating navigation (caret moves, deletes) and
///   while an input-method composition is active, since those make the buffered text no longer what is
///   in front of the caret.
final class KeywordMatcher: Sendable {
    private struct RecentInput {
        var scalars: [Unicode.Scalar] = []
        /// UTF-16 units typed for each scalar in `scalars`; more than its own width after a composed mark.
        var typed: [Int] = []
    }

    private let store: KeywordIndexStore
    private let recent = OSAllocatedUnfairLock(initialState: RecentInput())

    init(store: KeywordIndexStore) {
        self.store = store
    }

    var bufferCapacity: Int { store.current.maxKeywordLength }
    var bufferedScalarCount: Int { recent.withLock { $0.scalars.count } }

    func invalidate() {
        recent.withLock { $0 = RecentInput() }
    }

    /// Feeds typed text and returns the first keyword it completes; scalars after that match in the same
    /// call are dropped, and the buffer is cleared.
    func feed(_ text: String) -> KeywordMatch? {
        let index = store.current
        return recent.withLock { input in
            let capacity = index.maxKeywordLength
            guard capacity > 0 else {
                input = RecentInput()
                return nil
            }
            for scalar in text.unicodeScalars {
                Self.append(scalar, to: &input, capacity: capacity)
                if let entry = index.entry(endingWith: input.scalars) {
                    let typedLength = input.typed.suffix(entry.scalars.count).reduce(0, +)
                    input = RecentInput()
                    return KeywordMatch(snippetID: entry.snippetID, keyword: entry.keyword, typedUTF16Length: typedLength)
                }
            }
            return nil
        }
    }

    private static func append(_ scalar: Unicode.Scalar, to input: inout RecentInput, capacity: Int) {
        if scalar.properties.canonicalCombiningClass != .notReordered, let last = input.scalars.last,
           let composed = compose(last, with: scalar) {
            input.scalars[input.scalars.count - 1] = composed
            input.typed[input.typed.count - 1] += scalar.utf16.count
            return
        }
        input.scalars.append(scalar)
        input.typed.append(scalar.utf16.count)
        if input.scalars.count > capacity {
            let excess = input.scalars.count - capacity
            input.scalars.removeFirst(excess)
            input.typed.removeFirst(excess)
        }
    }

    private static func compose(_ base: Unicode.Scalar, with mark: Unicode.Scalar) -> Unicode.Scalar? {
        var pair = String.UnicodeScalarView()
        pair.append(base)
        pair.append(mark)
        let composed = String(pair).precomposedStringWithCanonicalMapping.unicodeScalars
        return composed.count == 1 ? composed.first : nil
    }
}
