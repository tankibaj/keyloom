import Foundation

enum SnippetIcon: Codable, Sendable, Hashable {
    case emoji(String)
    case symbol(String)
}

/// `id` never changes: renames and icon changes keep it, so references and sync records stay valid.
struct Snippet: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var icon: SnippetIcon
    var keyword: String?
    var enabled: Bool
    var tags: [String]
    var pinned: Bool
    var revision: Int
    var template: Document
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    /// `now` is injected so callers and tests control the clock.
    init(id: UUID = UUID(), name: String, icon: SnippetIcon, keyword: String? = nil, enabled: Bool = true,
         tags: [String] = [], pinned: Bool = false, revision: Int = 1, template: Document,
         createdAt: Date, updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.keyword = keyword
        self.enabled = enabled
        self.tags = tags
        self.pinned = pinned
        self.revision = revision
        self.template = template
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    mutating func rename(to newName: String, at now: Date) throws {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyloomError.invalidSnippet(field: "name", reason: "must not be blank")
        }
        name = newName
        touch(at: now)
    }

    mutating func setIcon(_ newIcon: SnippetIcon, at now: Date) {
        icon = newIcon
        touch(at: now)
    }

    private mutating func touch(at now: Date) {
        revision += 1
        updatedAt = now
    }
}
