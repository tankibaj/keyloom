import Foundation
import os

/// A keyword that is eligible for expansion: enabled snippet, non-empty keyword. Keywords are held in
/// canonical composed form (NFC), so `ü` and `u` + U+0308 are the same keyword. Matching stays
/// case-sensitive and compares Unicode scalars, never grapheme clusters.
struct ActiveKeyword: Sendable, Hashable {
    let snippetID: UUID
    let keyword: String

    static func from(_ snippets: [Snippet]) -> [ActiveKeyword] {
        snippets.compactMap { snippet in
            guard snippet.enabled, let keyword = snippet.keyword, !keyword.isEmpty else { return nil }
            return ActiveKeyword(snippetID: snippet.id, keyword: keyword.precomposedStringWithCanonicalMapping)
        }
    }
}

/// `typedUTF16Length` is how many UTF-16 units the user typed for the keyword, which is what the
/// expander must delete. It can exceed the keyword's own length: a combining mark that composed into
/// the previous scalar (`u` + U+0308 typed for `ü`) still counts as typed.
struct KeywordMatch: Equatable, Sendable {
    let snippetID: UUID
    let keyword: String
    let typedUTF16Length: Int
}

/// Immutable lookup built from the enabled snippets' keywords. Build it off the keyboard callback, then
/// publish it through `KeywordIndexStore`.
///
/// When several keywords complete on the same scalar (`b` and `ab` after typing `ab`), the longest wins;
/// identical keywords resolve to the first snippet in input order. Keywords longer than
/// `maxKeywordScalars` are ignored so the recent-input buffer stays small whatever sync delivers.
// TODO(keyloom-mvp): ignored overlong keywords are silent; surface them in the editor's keyword validation, when the editor slice lands.
struct KeywordIndex: Sendable {
    static let maxKeywordScalars = 64
    static let empty = KeywordIndex(snippets: [])

    struct Entry: Sendable {
        let snippetID: UUID
        let keyword: String
        let scalars: [Unicode.Scalar]
    }

    private let entriesByLastScalar: [Unicode.Scalar: [Entry]]
    /// Scalars of the longest indexed keyword: the recent-input buffer never needs more.
    let maxKeywordLength: Int
    let keywordCount: Int

    init(snippets: [Snippet]) {
        var byLast: [Unicode.Scalar: [Entry]] = [:]
        var longest = 0
        var count = 0
        for active in ActiveKeyword.from(snippets) {
            let scalars = Array(active.keyword.unicodeScalars)
            guard let last = scalars.last, scalars.count <= Self.maxKeywordScalars else { continue }
            byLast[last, default: []].append(Entry(snippetID: active.snippetID, keyword: active.keyword, scalars: scalars))
            longest = max(longest, scalars.count)
            count += 1
        }
        // Stable sort: longest first, input order among equals.
        entriesByLastScalar = byLast.mapValues { entries in
            entries.enumerated().sorted { ($0.element.scalars.count, $1.offset) > ($1.element.scalars.count, $0.offset) }.map(\.element)
        }
        maxKeywordLength = longest
        keywordCount = count
    }

    /// The keyword that `recent` ends with, if any.
    func entry(endingWith recent: [Unicode.Scalar]) -> Entry? {
        guard let last = recent.last, let candidates = entriesByLastScalar[last] else { return nil }
        return candidates.first { $0.scalars.count <= recent.count && recent.suffix($0.scalars.count).elementsEqual($0.scalars) }
    }
}

/// Owner of the current index. `replace` swaps it atomically; `current` is a short lock-protected read of an
/// immutable value, so a keyboard callback never waits on database or cloud work.
final class KeywordIndexStore: Sendable {
    private let lock: OSAllocatedUnfairLock<KeywordIndex>

    init(_ index: KeywordIndex = .empty) {
        lock = OSAllocatedUnfairLock(initialState: index)
    }

    var current: KeywordIndex { lock.withLock { $0 } }

    func replace(_ index: KeywordIndex) {
        lock.withLock { $0 = index }
    }
}
