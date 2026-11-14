import CryptoKit
import Foundation

enum SnapshotKind: String, Sendable, Equatable, CaseIterable {
    case daily
    case preImport = "preimport"
    case preRestore = "prerestore"
}

/// A snapshot file as listed: read from its name only, so a damaged file still shows up (and can be pruned).
struct SnapshotInfo: Equatable, Sendable {
    let url: URL
    let kind: SnapshotKind
    let createdAt: Date
    /// Orders snapshots taken within the same second.
    let sequence: Int
}

struct SnapshotContents: Equatable, Sendable {
    let info: SnapshotInfo
    let snippets: [Snippet]
}

/// Typed snapshot failures. Payloads are fixed labels and versions, never paths or snippet text.
enum SnapshotError: Error, Equatable, Sendable {
    /// The file is missing or cannot be read.
    case unreadable
    /// Truncated, damaged, edited, or its content does not match the fingerprint written with it.
    case corrupt
    /// Written by a newer Keyloom.
    case unsupportedVersion(found: Int, supported: Int)
    /// Nothing was published: no partial snapshot remains. `context` is `directory` or `write`.
    case writeFailed(context: String)
}

extension SnapshotError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadable: "The snapshot could not be read."
        case .corrupt: "The snapshot is damaged, so nothing was restored."
        case .unsupportedVersion(let found, let supported):
            "The snapshot was made by a newer Keyloom (format \(found); this version reads up to \(supported)). Update Keyloom to restore it."
        case .writeFailed(let context): "Saving a snapshot failed (\(context)); the library was not changed."
        }
    }
}

enum SnapshotFingerprint {
    /// SHA-256 over the library's content, independent of order and of device-local usage, so it changes exactly
    /// when a snippet is added, removed or edited (or its revision moves).
    static func of(_ snippets: [Snippet]) throws -> String {
        let canonical = snippets.map { snippet -> Snippet in
            var copy = snippet
            copy.lastUsedAt = nil
            return copy
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(canonical)).map { String(format: "%02x", $0) }.joined()
    }
}
