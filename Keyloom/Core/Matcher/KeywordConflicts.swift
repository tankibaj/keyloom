import Foundation

/// Two or more enabled snippets with the same keyword. All ids, in input order.
struct KeywordConflict: Equatable, Sendable {
    let keyword: String
    let snippetIDs: [UUID]
}

/// `shorter` completes while typing `longer`. `.prefix`: `shorter` starts `longer`, so it expands first and
/// `longer` can never be typed. `.suffix`: `shorter` ends `longer`; both complete on the same scalar and
/// the longer one wins, but `shorter` still fires after any other text. `.contains`: `shorter` sits strictly
/// inside `longer`, so it completes first and `longer` can never be typed. One finding per pair, strongest
/// kind first (prefix, suffix, contains).
struct KeywordOverlap: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case prefix, suffix, contains }

    let kind: Kind
    let shorter: String
    let shorterSnippetIDs: [UUID]
    let longer: String
    let longerSnippetIDs: [UUID]
}

/// Duplicate and overlap findings over the same active keywords the matcher indexes (enabled, non-empty,
/// canonical NFC, case-sensitive). Scalar-wise prefixes, suffixes and interior occurrences, matching the matcher.
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

        let keywordLengths = Set(idsByKeyword.keys.map(\.unicodeScalars.count))
        var overlaps: [KeywordOverlap] = []
        for (longer, longerIDs) in idsByKeyword {
            let scalars = Array(longer.unicodeScalars)
            var found = Set<String>()
            func report(_ kind: KeywordOverlap.Kind, _ shorter: String) {
                guard found.insert(shorter).inserted, let ids = idsByKeyword[shorter] else { return }
                overlaps.append(KeywordOverlap(kind: kind, shorter: shorter, shorterSnippetIDs: ids, longer: longer, longerSnippetIDs: longerIDs))
            }
            for length in 1..<max(scalars.count, 1) {
                report(.prefix, string(scalars[..<length]))
                report(.suffix, string(scalars[(scalars.count - length)...]))
            }
            for length in keywordLengths where length < scalars.count - 1 {
                for start in 1...(scalars.count - length - 1) { report(.contains, string(scalars[start..<(start + length)])) }
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
