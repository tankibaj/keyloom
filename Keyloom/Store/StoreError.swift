import Foundation

/// Typed failures of the local store. Payloads are IDs, counts and SQLite result codes, never snippet
/// text, keywords or SQL, so an error is always safe to log.
enum StoreError: Error, Equatable, Sendable {
    case closed
    case notFound(id: UUID)
    case alreadyExists(id: UUID)
    /// Restore or purge of a snippet that is not in the trash.
    case notDeleted(id: UUID)
    /// Another enabled, live snippet already owns the keyword.
    case keywordConflict(existingID: UUID)
    case corruptRecord(column: String)
    case sqlite(code: Int32, context: String)
}

extension StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .closed: "The snippet library is closed."
        case .notFound: "The snippet does not exist."
        case .alreadyExists: "A snippet with this ID already exists."
        case .notDeleted: "The snippet is not in the trash."
        case .keywordConflict: "Another enabled snippet already uses this keyword."
        case .corruptRecord(let column): "A stored snippet has an unreadable \(column) value."
        case .sqlite(let code, let context): "The snippet library failed (\(context), SQLite code \(code))."
        }
    }
}
