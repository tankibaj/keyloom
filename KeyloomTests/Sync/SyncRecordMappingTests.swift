import CloudKit
import XCTest
@testable import Keyloom

/// D1: the Snippet <-> CloudKit record mapping, with real `CKRecord` values (no network, no entitlement needed).
final class SyncRecordMappingTests: StoreTestCase {
    private func richSnippet() -> Snippet {
        let template = Document(paragraphs: [
            Paragraph(kind: .bullet, runs: [Run(style: [.bold], spans: [.literal("Hi "),
                .token(Token(kind: .argument(name: "who", defaultValue: "you", choices: ["a", "b"]), raw: "{argument name=\"who\"}"))])]),
            Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("Grüße 👩‍💻"), .token(Token(kind: .cursor, raw: "{cursor}"))])]),
        ])
        return Snippet(id: UUID(), name: "Gruß", icon: .emoji("👋"), keyword: ";gruss", enabled: false, tags: ["one", "two"],
                       pinned: true, revision: 7, template: template, createdAt: clock.now, updatedAt: clock.now.addingTimeInterval(60),
                       lastUsedAt: clock.now)
    }

    private func record(for snippet: Snippet) throws -> CKRecord {
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: SnippetRecord.recordID(snippet.id))
        try SnippetRecord.fill(record, from: snippet)
        return record
    }

    func testEveryFieldRoundTripsAndTheRecordIsNamedByTheSnippetID() throws {
        let snippet = richSnippet()
        let record = try record(for: snippet)
        XCTAssertEqual(record.recordID.recordName, snippet.id.uuidString)
        XCTAssertEqual(record.recordID.zoneID.zoneName, SnippetRecord.zoneName)
        var expected = snippet
        expected.lastUsedAt = nil
        XCTAssertEqual(try SnippetRecord.snippet(from: record), expected)
    }

    func testASymbolColorRoundTripsAndARecordWithoutOneReadsAsNoColor() throws {
        var snippet = richSnippet()
        snippet.icon = .symbol("bolt", color: .orange)
        let tinted = try record(for: snippet)
        XCTAssertEqual(tinted["iconColor"] as? String, "orange")
        XCTAssertEqual(tinted["schema"] as? Int, 1, "the record schema stays 1: records without the field still decode")
        XCTAssertEqual(try SnippetRecord.snippet(from: tinted).icon, .symbol("bolt", color: .orange))

        // A record an earlier build wrote has no iconColor field.
        let legacy = try record(for: snippet)
        legacy["iconColor"] = nil
        XCTAssertEqual(try SnippetRecord.snippet(from: legacy).icon, .symbol("bolt", color: nil))

        // Refilling after the color is removed removes it from the record too; an emoji never carries one.
        snippet.icon = .symbol("bolt")
        try SnippetRecord.fill(tinted, from: snippet)
        XCTAssertNil(tinted["iconColor"])
        let unknown = try record(for: richSnippet())
        unknown["iconKind"] = "symbol" as CKRecordValue
        unknown["iconValue"] = "bolt" as CKRecordValue
        unknown["iconColor"] = "chartreuse" as CKRecordValue
        XCTAssertEqual(try SnippetRecord.snippet(from: unknown).icon, .symbol("bolt", color: nil), "an unknown name is no color, not a failure")
    }

    func testDeviceLocalUsageNeverLeavesTheMac() throws {
        let keys = Set(try record(for: richSnippet()).allKeys())
        XCTAssertFalse(keys.contains { $0.lowercased().contains("used") || $0.lowercased().contains("count") }, "\(keys)")
    }

    func testAnAbsentKeywordAndEmptyTagsRoundTrip() throws {
        var snippet = richSnippet()
        snippet.keyword = nil
        snippet.tags = []
        let back = try SnippetRecord.snippet(from: try record(for: snippet))
        XCTAssertNil(back.keyword)
        XCTAssertEqual(back.tags, [])
    }

    func testRefillingARecordReplacesTheOldValues() throws {
        var snippet = richSnippet()
        let record = try record(for: snippet)
        snippet.keyword = nil
        snippet.name = "Changed"
        try SnippetRecord.fill(record, from: snippet)
        let back = try SnippetRecord.snippet(from: record)
        XCTAssertNil(back.keyword, "a removed keyword is removed from the record, not left behind")
        XCTAssertEqual(back.name, "Changed")
    }

    func testRecordsThisBuildCannotTrustAreRejectedWithTypedErrors() throws {
        let good = try record(for: richSnippet())
        func mutated(_ change: (CKRecord) -> Void) -> CKRecord {
            let copy = CKRecord(recordType: good.recordType, recordID: good.recordID)
            for key in good.allKeys() { copy[key] = good[key] }
            change(copy)
            return copy
        }
        XCTAssertThrowsError(try SnippetRecord.snippet(from: mutated { $0["schema"] = 2 as CKRecordValue })) {
            XCTAssertEqual($0 as? SnippetRecordError, .unsupportedSchema(found: 2))
        }
        XCTAssertThrowsError(try SnippetRecord.snippet(from: mutated { $0["name"] = nil })) {
            XCTAssertEqual($0 as? SnippetRecordError, .missingField("name"))
        }
        XCTAssertThrowsError(try SnippetRecord.snippet(from: mutated { $0["enabled"] = "yes" as CKRecordValue })) {
            XCTAssertEqual($0 as? SnippetRecordError, .missingField("enabled"))
        }
        XCTAssertThrowsError(try SnippetRecord.snippet(from: mutated { $0["iconKind"] = "sticker" as CKRecordValue })) {
            XCTAssertEqual($0 as? SnippetRecordError, .missingField("iconKind"))
        }
        XCTAssertThrowsError(try SnippetRecord.snippet(from: mutated { $0["template"] = Data("{}".utf8) as CKRecordValue })) {
            XCTAssertEqual($0 as? SnippetRecordError, .invalidTemplate)
        }
        let wrongType = CKRecord(recordType: "Other", recordID: good.recordID)
        XCTAssertThrowsError(try SnippetRecord.snippet(from: wrongType)) { XCTAssertEqual($0 as? SnippetRecordError, .wrongRecordType) }
        let badName = CKRecord(recordType: SnippetRecord.recordType, recordID: CKRecord.ID(recordName: "not-a-uuid"))
        XCTAssertThrowsError(try SnippetRecord.snippet(from: badName)) { XCTAssertEqual($0 as? SnippetRecordError, .recordNameIsNotAnID) }
    }

    func testARecordTooLargeForCloudKitIsRefusedBeforeSending() throws {
        var snippet = richSnippet()
        snippet.name = String(repeating: "n", count: 950_000)
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: SnippetRecord.recordID(snippet.id))
        XCTAssertThrowsError(try SnippetRecord.fill(record, from: snippet)) {
            XCTAssertEqual($0 as? SnippetRecordError, .tooLarge)
        }
    }

    func testServerTagsSurviveArchivingAndAForeignOrBrokenArchiveYieldsAFreshRecord() throws {
        let snippet = richSnippet()
        let original = try record(for: snippet)
        let archived = SnippetRecord.archivedSystemFields(of: original)
        let restored = SnippetRecord.record(for: snippet.id, systemFields: archived)
        XCTAssertEqual(restored.recordID, original.recordID)
        XCTAssertEqual(restored.recordType, SnippetRecord.recordType)

        let other = SnippetRecord.record(for: UUID(), systemFields: archived)
        XCTAssertNotEqual(other.recordID, original.recordID, "tags of another record are never reused")
        let broken = SnippetRecord.record(for: snippet.id, systemFields: Data("garbage".utf8))
        XCTAssertEqual(broken.recordID.recordName, snippet.id.uuidString)
        let none = SnippetRecord.record(for: snippet.id, systemFields: nil)
        XCTAssertEqual(none.recordID.recordName, snippet.id.uuidString)
    }

    func testFailureKindsAreClassifiedWithoutLeakingContent() {
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.networkUnavailable)), .networkUnavailable)
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.requestRateLimited)), .networkUnavailable)
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.notAuthenticated)), .notAuthenticated)
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.limitExceeded)), .recordTooLarge)
        XCTAssertEqual(CKSyncEngineAdapter.failureKind(of: CKError(.internalError)), .other(code: CKError.Code.internalError.rawValue))
    }

    func testAnUnprovisionedBuildNeverTouchesCloudKit() async {
        // The test host is ad-hoc signed without the iCloud entitlement: the adapter must say so, not crash.
        let status = await CKSyncEngineAdapter().accountStatus()
        XCTAssertEqual(status, .buildNotProvisioned)
    }
}
