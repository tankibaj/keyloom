import Foundation

/// One file entry as the import would treat it. `snippet` is what would be stored: its keyword is kept but
/// `enabled` is already false when `conflictsWith` is set.
struct ImportItem: Equatable, Sendable, Identifiable {
    let index: Int
    let snippet: Snippet
    /// Same content as this snippet (already in the library or earlier in the file): skipped, not importable.
    let duplicateOf: UUID?
    /// The enabled snippet that owns this keyword: the import is kept, disabled.
    let conflictsWith: UUID?
    /// The file's id is already taken by different content, so the import gets a fresh id.
    let idReassigned: Bool
    let unsupportedTokens: [String]
    let templateKeptLiteral: Bool

    var id: Int { index }
    var isImportable: Bool { duplicateOf == nil }
}

/// The read-only outcome of looking at an import file. Nothing has been written; `selected` is the set a
/// caller commits in one transaction.
struct ImportPreview: Equatable, Sendable {
    let format: ImportFormat
    let items: [ImportItem]
    let malformed: [MalformedEntry]

    var importable: [ImportItem] { items.filter(\.isImportable) }

    /// Importable items among `indices` (all importable items when nil), in file order.
    func selected(_ indices: Set<Int>?) -> [ImportItem] {
        importable.filter { indices?.contains($0.index) ?? true }
    }
}

/// Pure planning step: no I/O, no clock, no randomness beyond the injected `makeID`.
///
/// Rules:
/// - Identical duplicate: same name, keyword, icon, tags and document as a snippet already in the library or
///   earlier in the file (id, revision, dates, pin and enabled state do not matter). Raycast records carry only
///   name, keyword and text, so they compare name, keyword and plain text. Skipped.
/// - Conflict: an enabled entry whose keyword (canonical NFC) an enabled snippet already owns, in the library
///   or earlier in the file. Kept, disabled.
/// - Id collision with different content: a copy under a fresh id and revision 1; the existing snippet is never
///   overwritten.
enum ImportPlanner {
    static func preview(_ data: Data, existing: [Snippet], now: Date, makeID: () -> UUID) throws -> ImportPreview {
        let decoded: DecodedImport
        switch try detectFormat(data) {
        case .keyloom: decoded = try NativeFormat.decode(data)
        case .raycast: decoded = try RaycastFormat.decode(data, now: now, makeID: makeID)
        }
        return plan(decoded, existing: existing, now: now, makeID: makeID)
    }

    private static func detectFormat(_ data: Data) throws -> ImportFormat {
        switch data.first(where: { !" \t\r\n".utf8.contains($0) }) {
        case UInt8(ascii: "["): return .raycast
        case UInt8(ascii: "{"): return .keyloom
        default:
            try ImportFileGuard.check(data)
            throw PortabilityError.notRecognized
        }
    }

    private struct ContentKey: Hashable {
        let name: String
        let keyword: String?
    }

    static func plan(_ decoded: DecodedImport, existing: [Snippet], now: Date, makeID: () -> UUID) -> ImportPreview {
        var knownIDs = Set(existing.map(\.id))
        var byContent: [ContentKey: [Snippet]] = [:]
        var keywordOwners: [String: UUID] = [:]
        func register(_ snippet: Snippet) {
            knownIDs.insert(snippet.id)
            byContent[ContentKey(name: snippet.name, keyword: snippet.keyword), default: []].append(snippet)
            if snippet.enabled, let keyword = snippet.keyword { keywordOwners[keyword] = keywordOwners[keyword] ?? snippet.id }
        }
        existing.forEach(register)

        let items = decoded.candidates.map { candidate -> ImportItem in
            var snippet = candidate.snippet
            let twins = byContent[ContentKey(name: snippet.name, keyword: snippet.keyword)] ?? []
            if let twin = twins.first(where: { isIdentical($0, snippet, format: decoded.format) }) {
                return item(candidate, snippet: snippet, duplicateOf: twin.id)
            }
            var reassigned = false
            if knownIDs.contains(snippet.id) {
                snippet = Snippet(id: makeID(), name: snippet.name, icon: snippet.icon, keyword: snippet.keyword,
                                  enabled: snippet.enabled, tags: snippet.tags, pinned: snippet.pinned, revision: 1,
                                  template: snippet.template, createdAt: now)
                reassigned = true
            }
            var conflict: UUID?
            if snippet.enabled, let keyword = snippet.keyword, let owner = keywordOwners[keyword] {
                snippet.enabled = false
                conflict = owner
            }
            register(snippet)
            return item(candidate, snippet: snippet, conflictsWith: conflict, idReassigned: reassigned)
        }
        return ImportPreview(format: decoded.format, items: items, malformed: decoded.malformed)
    }

    private static func item(_ candidate: ImportCandidate, snippet: Snippet, duplicateOf: UUID? = nil,
                             conflictsWith: UUID? = nil, idReassigned: Bool = false) -> ImportItem {
        ImportItem(index: candidate.index, snippet: snippet, duplicateOf: duplicateOf, conflictsWith: conflictsWith,
                   idReassigned: idReassigned, unsupportedTokens: candidate.unsupportedTokens,
                   templateKeptLiteral: candidate.templateKeptLiteral)
    }

    /// Name and keyword already match (the lookup key).
    private static func isIdentical(_ existing: Snippet, _ incoming: Snippet, format: ImportFormat) -> Bool {
        switch format {
        case .keyloom:
            existing.icon == incoming.icon && existing.tags == incoming.tags && existing.template == incoming.template
        case .raycast:
            existing.template.plainText == incoming.template.plainText
        }
    }
}
