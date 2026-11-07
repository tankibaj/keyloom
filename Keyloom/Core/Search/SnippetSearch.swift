import Foundation

/// Where a query matched, best first. `Comparable` order is the ranking: name prefix, name, keyword, tag, body.
enum SearchField: Int, Comparable, Sendable {
    case namePrefix, name, keyword, tag, body

    static func < (lhs: SearchField, rhs: SearchField) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// `field` is the best field the query matched, or nil when the query was empty.
struct SearchHit: Equatable, Sendable {
    let snippet: Snippet
    let field: SearchField?
}

/// An empty result always says why: nothing in the library, or nothing matching the query and tags.
enum SearchOutcome: Equatable, Sendable {
    case emptyLibrary
    case noMatches
    case results([SearchHit])
}

/// Work counters so tests can bound the cost of a search without timing it.
struct SearchStats: Sendable {
    var fieldComparisons = 0
    var foldOperations = 0
}

/// Search over name, keyword, tags and body `plainText`, case- and diacritic-insensitive.
///
/// Each snippet's fields are folded once when the index is built, so a query folds only itself and compares
/// each field at most once: one pass over ~1 MiB of text. Rank is the best matching field; equal ranks keep
/// library order. The query is one trimmed substring, not split into words. A tag filter keeps only
/// snippets that carry every selected tag (AND), compared case- and diacritic-insensitively.
struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        var snippet: Snippet
        let name: String
        let keyword: String
        let tags: [String]
        let joinedTags: String
        let body: String
    }

    private var entries: [Entry]

    init(snippets: [Snippet]) {
        entries = snippets.map { snippet in
            let tags = snippet.tags.map(Self.fold)
            return Entry(snippet: snippet, name: Self.fold(snippet.name), keyword: Self.fold(snippet.keyword ?? ""),
                         tags: tags, joinedTags: tags.joined(separator: "\n"), body: Self.fold(snippet.template.plainText))
        }
    }

    /// Usage is device-local metadata outside every searched field, so it is patched in place instead of rebuilding.
    mutating func setLastUsedAt(_ date: Date, for id: UUID) {
        guard let offset = entries.firstIndex(where: { $0.snippet.id == id }) else { return }
        entries[offset].snippet.lastUsedAt = date
    }

    func search(query: String, tags: Set<String> = []) -> SearchOutcome {
        var stats = SearchStats()
        return search(query: query, tags: tags, stats: &stats)
    }

    func search(query: String, tags: Set<String>, stats: inout SearchStats) -> SearchOutcome {
        guard !entries.isEmpty else { return .emptyLibrary }
        stats.foldOperations += 1
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let wantedTags = tags.map(Self.fold)

        var ranked: [(offset: Int, hit: SearchHit)] = []
        for (offset, entry) in entries.enumerated() where wantedTags.allSatisfy({ entry.tags.contains($0) }) {
            if needle.isEmpty {
                ranked.append((offset, SearchHit(snippet: entry.snippet, field: nil)))
            } else if let field = Self.bestField(of: entry, matching: needle, stats: &stats) {
                ranked.append((offset, SearchHit(snippet: entry.snippet, field: field)))
            }
        }
        guard !ranked.isEmpty else { return .noMatches }
        ranked.sort { lhs, rhs in
            lhs.hit.field == rhs.hit.field ? lhs.offset < rhs.offset : (lhs.hit.field ?? .body) < (rhs.hit.field ?? .body)
        }
        return .results(ranked.map(\.hit))
    }

    private static func bestField(of entry: Entry, matching needle: String, stats: inout SearchStats) -> SearchField? {
        stats.fieldComparisons += 1
        if entry.name.hasPrefix(needle) { return .namePrefix }
        if entry.name.contains(needle) { return .name }
        stats.fieldComparisons += 1
        if entry.keyword.contains(needle) { return .keyword }
        stats.fieldComparisons += 1
        if entry.joinedTags.contains(needle) { return .tag }
        stats.fieldComparisons += 1
        return entry.body.contains(needle) ? .body : nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
