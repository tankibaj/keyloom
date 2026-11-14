/// Typed failures of the Keyloom core. Payloads never carry user text.
enum KeyloomError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case malformedDocument(reason: String)
    /// `limit` names the `DocumentLimits` member that was exceeded.
    case documentTooLarge(limit: String, maximum: Int)
    case multipleCursors(count: Int)
    case offsetOutOfBounds(offset: Int, length: Int)
    case offsetNotOnScalarBoundary(offset: Int)
    case cursorInsideScalar(offset: Int)
    case invalidRange(start: Int, end: Int)
    case invalidSnippet(field: String, reason: String)
}
