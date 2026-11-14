import Foundation

/// File-level import failures. The file is refused whole and nothing is written. Payloads are counts and
/// versions, never file text.
enum PortabilityError: Error, Equatable, Sendable {
    /// Neither a Keyloom export nor a JSON array of Raycast records.
    case notRecognized
    /// Recognizable but unreadable: truncated or structurally broken JSON.
    case malformedFile
    /// Written by a newer Keyloom. Refused before the body is read.
    case unsupportedFormatVersion(found: Int, supported: Int)
    case fileTooLarge(maximumBytes: Int)
    case tooManyEntries(maximum: Int)
}

extension PortabilityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notRecognized: "This file is not a Keyloom export or a Raycast snippets file."
        case .malformedFile: "This file is damaged or incomplete, so nothing was imported."
        case .unsupportedFormatVersion(let found, let supported):
            "This file was exported by a newer Keyloom (format \(found); this version reads up to \(supported)). Update Keyloom to import it."
        case .fileTooLarge(let maximum): "This file is larger than the import limit of \(maximum / 1_048_576) MB."
        case .tooManyEntries(let maximum): "This file has more than \(maximum) snippets, more than one import accepts."
        }
    }
}

enum ImportLimits {
    static let maxFileBytes = 16 * 1_048_576
    static let maxEntries = 10_000
}

enum ImportFormat: Equatable, Sendable {
    case keyloom, raycast
}

/// Why one entry of an otherwise readable file cannot be imported. Never carries entry text.
enum MalformedReason: Error, Equatable, Sendable {
    /// Not an object, or fields of the wrong type.
    case invalidStructure
    case missingField(String)
    case invalidField(String)
    /// A native snippet whose document comes from a newer Keyloom.
    case unsupportedDocumentVersion(found: Int)
    /// A document over the size limits or otherwise invalid.
    case invalidDocument
}

struct MalformedEntry: Equatable, Sendable {
    /// Position in the file's list, from 0.
    let index: Int
    let reason: MalformedReason
}

/// One entry that decoded and validated, before it is compared with the library.
struct ImportCandidate: Equatable, Sendable {
    let index: Int
    let snippet: Snippet
    /// Source of each token this build cannot interpret. They stay in the template as literal text.
    let unsupportedTokens: [String]
    /// The template had token syntax errors (a stray `{`), so it was kept as plain literal text.
    let templateKeptLiteral: Bool
}

struct DecodedImport: Equatable, Sendable {
    let format: ImportFormat
    let candidates: [ImportCandidate]
    let malformed: [MalformedEntry]
}

enum LossKind: Hashable, Sendable {
    case textStyles, listFormatting, tags, pinned, disabled
}

/// What a Raycast export drops for one snippet.
struct FormattingLoss: Equatable, Sendable {
    let snippetID: UUID
    let kinds: Set<LossKind>
}

extension Snippet {
    /// Every unsupported token in the template, in order.
    var unsupportedTokenSources: [String] {
        template.paragraphs.flatMap(\.runs).flatMap(\.spans).compactMap { span in
            if case .token(let token) = span, case .unsupported(let raw) = token.kind { return raw }
            return nil
        }
    }
}

enum ImportFileGuard {
    /// Size gate shared by both formats; runs before any parsing.
    static func check(_ data: Data) throws {
        guard data.count <= ImportLimits.maxFileBytes else {
            throw PortabilityError.fileTooLarge(maximumBytes: ImportLimits.maxFileBytes)
        }
    }

    static func check(entryCount: Int) throws {
        guard entryCount <= ImportLimits.maxEntries else {
            throw PortabilityError.tooManyEntries(maximum: ImportLimits.maxEntries)
        }
    }
}
