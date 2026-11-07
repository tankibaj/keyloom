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

/// A stored row this build cannot decode (a template from a newer app, a damaged document or ID). It is left
/// untouched and hidden from listings; delete or purge it by `rowID`, or update the app. `rowID` is the raw
/// column, because the ID itself may be what is damaged. Never carries snippet text.
struct UnreadableRecord: Sendable, Hashable {
    let rowID: String
    let isDeleted: Bool
}

/// What `SnippetStore.contents()` reads in one pass.
struct StoreContents: Sendable, Equatable {
    /// Live snippets in the default order.
    let snippets: [Snippet]
    /// Live and trashed rows that could not be read, by row ID.
    let unreadable: [UnreadableRecord]
}
