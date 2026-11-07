import Foundation

struct TagSummary: Sendable, Equatable {
    let tag: String
    /// Live (not deleted) snippets carrying the tag.
    let count: Int
}

/// Device-local usage. Not part of a snippet's revision and never synced.
struct SnippetUsage: Sendable, Equatable {
    let lastUsedAt: Date?
    let useCount: Int
}

struct DeletedSnippet: Sendable, Equatable {
    let snippet: Snippet
    let deletedAt: Date
}

/// The snippet as it was saved at `revision`.
struct SnippetRevision: Sendable, Equatable {
    let revision: Int
    let recordedAt: Date
    let snippet: Snippet
}
