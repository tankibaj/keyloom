import Foundation

/// Two or more enabled snippets with the same keyword. All ids, in input order.
struct KeywordConflict: Equatable, Sendable {
    let keyword: String
    let snippetIDs: [UUID]
}

/// `shorter` completes while typing `longer`. `.prefix`: `shorter` starts `longer`, so it expands first and
/// `longer` can never be typed. `.suffix`: `shorter` ends `longer`; both complete on the same scalar and
/// the longer one wins, but `shorter` still fires after any other text.
struct KeywordOverlap: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case prefix, suffix }

    let kind: Kind
    let shorter: String
    let shorterSnippetIDs: [UUID]
    let longer: String
    let longerSnippetIDs: [UUID]
}

/// Duplicate and overlap findings over the same active keywords the matcher indexes (enabled, non-empty,
/// canonical NFC, case-sensitive). Scalar-wise prefixes and suffixes, matching the matcher.
struct KeywordConflicts: Equatable, Sendable {
    let conflicts: [KeywordConflict]
    let overlaps: [KeywordOverlap]

    /// Deterministic regardless of input order: overlaps sort by longer keyword (length, then scalars), then shorter keyword the same way.
    static func analyze(_ snippets: [Snippet]) -> KeywordConflicts {
        var idsByKeyword: [String: [UUID]] = [:]
        for active in ActiveKeyword.from(snippets) {
            idsByKeyword[active.keyword, default: []].append(active.snippetID)
        }
        let conflicts = idsByKeyword.filter { $0.value.count > 1 }
            .map { KeywordConflict(keyword: $0.key, snippetIDs: $0.value) }
            .sorted { $0.keyword.unicodeScalars.lexicographicallyPrecedes($1.keyword.unicodeScalars) }

        var overlaps: [KeywordOverlap] = []
        for (longer, longerIDs) in idsByKeyword {
            let scalars = Array(longer.unicodeScalars)
            for length in 1..<max(scalars.count, 1) {
                let prefix = string(scalars[..<length])
                let suffix = string(scalars[(scalars.count - length)...])
                if let ids = idsByKeyword[prefix] {
                    overlaps.append(KeywordOverlap(kind: .prefix, shorter: prefix, shorterSnippetIDs: ids, longer: longer, longerSnippetIDs: longerIDs))
                }
                if suffix != prefix, let ids = idsByKeyword[suffix] {
                    overlaps.append(KeywordOverlap(kind: .suffix, shorter: suffix, shorterSnippetIDs: ids, longer: longer, longerSnippetIDs: longerIDs))
                }
            }
        }
        overlaps.sort { lhs, rhs in
            let l = [lhs.longer, lhs.shorter].map(\.unicodeScalars.count)
            let r = [rhs.longer, rhs.shorter].map(\.unicodeScalars.count)
            if l[0] != r[0] { return l[0] < r[0] }
            if lhs.longer != rhs.longer { return lhs.longer.unicodeScalars.lexicographicallyPrecedes(rhs.longer.unicodeScalars) }
            if l[1] != r[1] { return l[1] < r[1] }
            return lhs.shorter.unicodeScalars.lexicographicallyPrecedes(rhs.shorter.unicodeScalars)
        }
        return KeywordConflicts(conflicts: conflicts, overlaps: overlaps)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
