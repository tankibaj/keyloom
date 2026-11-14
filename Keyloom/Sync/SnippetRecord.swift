import CloudKit
import Foundation

enum SnippetRecordError: Error, Equatable {
    case wrongRecordType
    case recordNameIsNotAnID
    case missingField(String)
    /// Written by a newer Keyloom; this build must not guess at it.
    case unsupportedSchema(found: Int)
    case invalidTemplate
    /// Would exceed CloudKit's record size limit.
    // TODO(keyloom-wp5): upload very large templates as a CKAsset, when a user reports a snippet this big.
    case tooLarge
}

/// How a snippet is stored in the user's private CloudKit database: one record per snippet, named by the
/// snippet's UUID so every Mac addresses the same record. Device-local usage (last used, count) is never sent.
/// `iconColor` is optional on the wire (a record without it has no color), so the record schema stays 1; an older
/// build that saves such a record again drops the color.
/// Only plain values go over the wire: the template travels as the same versioned JSON the local store keeps.
enum SnippetRecord {
    static let recordType = "Snippet"
    static let zoneName = "KeyloomLibrary"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let currentSchema = 1
    /// CloudKit allows 1 MB per record; the rest of the fields are small next to a template.
    private static let maxPayloadBytes = 900_000

    private enum Field {
        static let schema = "schema"
        static let name = "name"
        static let iconKind = "iconKind"
        static let iconValue = "iconValue"
        static let iconColor = "iconColor"
        static let keyword = "keyword"
        static let enabled = "enabled"
        static let pinned = "pinned"
        static let tags = "tags"
        static let revision = "revision"
        static let template = "template"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
    }

    static func recordID(_ id: UUID, zoneID: CKRecordZone.ID = SnippetRecord.zoneID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    /// Whether the snippet's record stays inside CloudKit's size limit.
    static func fits(_ snippet: Snippet) -> Bool {
        (try? snippet.template.encoded()).map { payloadBytes(of: snippet, template: $0) <= maxPayloadBytes } ?? true
    }

    private static func payloadBytes(of snippet: Snippet, template: Data) -> Int {
        template.count + snippet.name.utf8.count + (snippet.keyword?.utf8.count ?? 0) + snippet.tags.reduce(0) { $0 + $1.utf8.count }
    }

    /// Writes every synced field of `snippet` into `record`, replacing earlier values.
    static func fill(_ record: CKRecord, from snippet: Snippet) throws {
        let template = try snippet.template.encoded()
        guard payloadBytes(of: snippet, template: template) <= maxPayloadBytes else { throw SnippetRecordError.tooLarge }
        let (kind, value, color): (String, String, IconColor?) = switch snippet.icon {
        case .emoji(let value): ("emoji", value, nil)
        case .symbol(let value, let color): ("symbol", value, color)
        }
        record[Field.schema] = currentSchema as CKRecordValue
        record[Field.name] = snippet.name as CKRecordValue
        record[Field.iconKind] = kind as CKRecordValue
        record[Field.iconValue] = value as CKRecordValue
        record[Field.iconColor] = color.map { $0.rawValue as CKRecordValue }
        record[Field.keyword] = snippet.keyword.map { $0 as CKRecordValue }
        record[Field.enabled] = (snippet.enabled ? 1 : 0) as CKRecordValue
        record[Field.pinned] = (snippet.pinned ? 1 : 0) as CKRecordValue
        record[Field.tags] = snippet.tags as CKRecordValue
        record[Field.revision] = snippet.revision as CKRecordValue
        record[Field.template] = template as CKRecordValue
        record[Field.createdAt] = snippet.createdAt as CKRecordValue
        record[Field.updatedAt] = snippet.updatedAt as CKRecordValue
    }

    /// The snippet a record describes. Structure only: content rules are enforced when the store applies it.
    /// `supportedSchema` is the newest record schema this build reads (a seam for tests; production uses the default).
    static func snippet(from record: CKRecord, supportedSchema: Int = currentSchema) throws -> Snippet {
        guard record.recordType == recordType else { throw SnippetRecordError.wrongRecordType }
        guard let id = UUID(uuidString: record.recordID.recordName) else { throw SnippetRecordError.recordNameIsNotAnID }
        func required<T>(_ field: String, as type: T.Type) throws -> T {
            guard let value = record[field] as? T else { throw SnippetRecordError.missingField(field) }
            return value
        }
        let schema = try required(Field.schema, as: Int.self)
        guard schema <= supportedSchema else { throw SnippetRecordError.unsupportedSchema(found: schema) }
        let templateData = try required(Field.template, as: Data.self)
        let template: Document
        do { template = try Document.decode(from: templateData) } catch { throw SnippetRecordError.invalidTemplate }
        let kind = try required(Field.iconKind, as: String.self)
        let value = try required(Field.iconValue, as: String.self)
        guard kind == "emoji" || kind == "symbol" else { throw SnippetRecordError.missingField(Field.iconKind) }
        return Snippet(id: id, name: try required(Field.name, as: String.self), icon: SnippetStore.icon(kind: kind, value: value, color: record[Field.iconColor] as? String),
                       keyword: record[Field.keyword] as? String, enabled: try required(Field.enabled, as: Int.self) == 1,
                       tags: (record[Field.tags] as? [String]) ?? [], pinned: (record[Field.pinned] as? Int) == 1,
                       revision: try required(Field.revision, as: Int.self), template: template,
                       createdAt: try required(Field.createdAt, as: Date.self), updatedAt: try required(Field.updatedAt, as: Date.self))
    }

    /// The server's version tag and identity, as the store keeps them: the record's archived system fields.
    static func archivedSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A record carrying the server's tag from `fields`, ready to be filled and sent as an update; a fresh
    /// record when there are none or they cannot be read.
    static func record(for id: UUID, systemFields fields: Data?, zoneID: CKRecordZone.ID = SnippetRecord.zoneID) -> CKRecord {
        if let fields, let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            if let record = CKRecord(coder: coder), record.recordID == recordID(id, zoneID: zoneID) { return record }
        }
        return CKRecord(recordType: recordType, recordID: recordID(id, zoneID: zoneID))
    }
}
