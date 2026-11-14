import CloudKit
import XCTest
@testable import Keyloom

/// Slice D2: concurrent edits reconcile against the agreed ancestor and never lose either side.
final class SyncConflictTests: SyncTestCase {
    private let account = "icloud:A"

    private func pair() async throws -> (SyncDevice, SyncDevice) {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        await first.enableSync()
        await second.enableSync()
        return (first, second)
    }

    private func names(_ device: SyncDevice) async throws -> [String] {
        try await device.store.allSnippets().map(\.name).sorted()
    }

    func testEditEditOnTwoMacsKeepsBothVersionsEverywhere() async throws {
        let (first, second) = try await pair()
        let original = try await first.store.create(makeSnippet(name: "Base", keyword: ";kw", text: "base"))
        await settle(first, second)

        var onFirst = original
        onFirst.name = "First edit"
        _ = try await first.store.update(onFirst)
        var onSecond = original
        onSecond.name = "Second edit"
        _ = try await second.store.update(onSecond)
        await settle(first, second)

        let firstNames = try await names(first)
        let secondNames = try await names(second)
        XCTAssertEqual(firstNames, secondNames, "both Macs converge")
        XCTAssertEqual(firstNames.count, 2, "both versions survive")
        XCTAssertTrue(firstNames.contains("First edit"))
        XCTAssertTrue(firstNames.contains { $0.hasPrefix("Second edit (conflict copy ") }, "the loser is named so it can be found: \(firstNames)")
        let all = try await first.store.allSnippets()
        XCTAssertEqual(all.filter { $0.enabled && $0.keyword == ";kw" }.count, 1, "the copy is disabled: the keyword stays unique")
        XCTAssertEqual(cloud.recordCount(account: account), 2)
        let firstPending = try await first.store.pending(account: account)
        let secondPending = try await second.store.pending(account: account)
        XCTAssertEqual(firstPending, [])
        XCTAssertEqual(secondPending, [])
    }

    func testDeletedOnOneMacEditedOnTheOtherKeepsTheEditAndTheDelete() async throws {
        let (first, second) = try await pair()
        let original = try await first.store.create(makeSnippet(name: "Base", keyword: ";kw"))
        await settle(first, second)

        try await first.store.delete(id: original.id)
        var edited = original
        edited.name = "Edited elsewhere"
        _ = try await second.store.update(edited)
        await first.sync()
        await settle(first, second)

        for device in [first, second] {
            let live = try await device.store.snippet(id: original.id)
            XCTAssertNil(live, "the delete is honored on the original")
            let all = try await device.store.allSnippets()
            XCTAssertEqual(all.count, 1)
            XCTAssertTrue(all[0].name.hasPrefix("Edited elsewhere (conflict copy "), "the edit survives as a named copy")
            XCTAssertTrue(all[0].enabled, "no other snippet holds the keyword, so the copy stays enabled")
        }
    }

    func testEditedAndPushedOnOneMacDeletedOnTheOtherKeepsTheEditAsACopy() async throws {
        let (first, second) = try await pair()
        let original = try await first.store.create(makeSnippet(name: "Base", keyword: ";kw"))
        await settle(first, second)

        var edited = original
        edited.name = "Edited and pushed"
        _ = try await first.store.update(edited)
        await first.sync()
        try await second.store.delete(id: original.id)
        await settle(second, first)

        for device in [first, second] {
            let live = try await device.store.snippet(id: original.id)
            XCTAssertNil(live)
            let all = try await device.store.allSnippets()
            XCTAssertEqual(all.map(\.name).count, 1)
            XCTAssertTrue(all[0].name.hasPrefix("Edited and pushed (conflict copy "), all[0].name)
        }
    }

    func testDuplicateActiveKeywordsAreResolvedBeforeTheCopyIsEnabled() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let mine = try await first.store.create(makeSnippet(name: "On first", keyword: ";dup"))
        let theirs = try await second.store.create(makeSnippet(name: "On second", keyword: ";dup"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        for device in [first, second] {
            let all = try await device.store.allSnippets()
            XCTAssertEqual(Set(all.map(\.id)), [mine.id, theirs.id], "both snippets exist on both Macs")
            XCTAssertEqual(KeywordConflicts.analyze(all).conflicts, [], "never two enabled snippets with one keyword")
            XCTAssertEqual(all.filter { $0.enabled && $0.keyword == ";dup" }.count, 1)
        }
        let firstOwner = try await first.store.allSnippets().first { $0.enabled }?.id
        let secondOwner = try await second.store.allSnippets().first { $0.enabled }?.id
        XCTAssertNotNil(firstOwner)
        XCTAssertEqual(firstOwner, secondOwner, "both Macs keep the same snippet enabled")
    }

    func testTwoMacsConvergeOnTheEarliestSnippetAndALaterTagEditDoesNotFlipIt() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let older = try await first.store.create(makeSnippet(name: "Older", keyword: ";x"))
        clock.advance(by: 60)
        let younger = try await second.store.create(makeSnippet(name: "Younger", keyword: ";x"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        for device in [first, second] {
            let all = try await device.store.allSnippets()
            XCTAssertEqual(all.filter { $0.enabled && $0.keyword == ";x" }.map(\.id), [older.id], "exactly the earliest copy is on")
        }

        // The user retags the disabled copy on one Mac; the other Mac must not end up with both off.
        let found = try await first.store.snippet(id: younger.id)
        var retagged = try XCTUnwrap(found)
        retagged.tags = ["fyi"]
        _ = try await first.store.update(retagged)
        await settle(first, second)
        await settle(second, first)

        for device in [first, second] {
            let all = try await device.store.allSnippets()
            XCTAssertEqual(all.filter { $0.enabled && $0.keyword == ";x" }.map(\.id), [older.id])
            let tags = all.first { $0.id == younger.id }?.tags
            XCTAssertEqual(tags, ["fyi"], "the edit itself still syncs")
        }
        XCTAssertEqual(cloud.snippets(account: account)[younger.id]?.enabled, true, "iCloud keeps the user's intent")
        let notice = try await second.store.keywordConflictDisabledIDs()
        XCTAssertEqual(notice, [younger.id], "the user can be told which snippet was turned off")
        let count = await second.controller.keywordConflictCount()
        XCTAssertEqual(count, 1)
    }

    func testDeletingTheKeywordWinnerOnOneMacTurnsTheLoserBackOnEverywhere() async throws {
        let first = try makeDevice(idStart: 10_000)
        let second = try makeDevice(idStart: 20_000)
        let older = try await first.store.create(makeSnippet(name: "Older", keyword: ";x"))
        clock.advance(by: 60)
        let younger = try await second.store.create(makeSnippet(name: "Younger", keyword: ";x"))
        await first.enableSync()
        await second.enableSync()
        await settle(first, second)

        try await first.store.delete(id: older.id)
        await settle(first, second)
        await settle(second, first)

        for device in [first, second] {
            let all = try await device.store.allSnippets()
            XCTAssertEqual(all.map(\.id), [younger.id])
            XCTAssertEqual(all.first?.enabled, true, "no duplicate and no dead keyword: the freed keyword works again")
            let pending = try await device.store.pending(account: account)
            XCTAssertEqual(pending, [])
        }
        XCTAssertEqual(cloud.snippets(account: account)[younger.id]?.enabled, true)
        let notices = await second.controller.keywordConflictCount()
        XCTAssertEqual(notices, 0)
    }

    func testEditsToDifferentFieldsOfDifferentSnippetsNeverConflict() async throws {
        let (first, second) = try await pair()
        let one = try await first.store.create(makeSnippet(name: "One", keyword: ";1"))
        let two = try await first.store.create(makeSnippet(name: "Two", keyword: ";2"))
        await settle(first, second)

        var editedOne = one
        editedOne.name = "One edited"
        _ = try await first.store.update(editedOne)
        var editedTwo = two
        editedTwo.name = "Two edited"
        _ = try await second.store.update(editedTwo)
        await settle(first, second)

        let firstNames = try await names(first)
        let secondNames = try await names(second)
        XCTAssertEqual(firstNames, ["One edited", "Two edited"])
        XCTAssertEqual(secondNames, firstNames)
    }

    func testRecordsThisBuildCannotReadAreSkippedAndCountedNotApplied() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let newer = makeSnippet(name: "From a newer Keyloom")
        let record = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(newer.id))
        try SnippetRecord.fill(record, from: newer)
        record["schema"] = 999 as CKRecordValue
        cloud.putExternally(account: account, record: record)
        let good = makeSnippet(name: "Readable", keyword: ";ok")
        let goodRecord = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(good.id))
        try SnippetRecord.fill(goodRecord, from: good)
        cloud.putExternally(account: account, record: goodRecord)

        await device.sync()

        let all = try await device.store.allSnippets()
        XCTAssertEqual(all.map(\.id), [good.id], "the readable record still arrives")
        let skipped = await device.controller.skippedRemoteRecords
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(cloud.recordCount(account: account), 2, "the unreadable record is left in iCloud untouched")
    }

    func testAnInvalidRemoteSnippetIsRejectedWithoutBlockingTheRest() async throws {
        let device = try makeDevice()
        await device.enableSync()
        let blank = makeSnippet(name: "   ")
        let blankRecord = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(blank.id))
        try SnippetRecord.fill(blankRecord, from: blank)
        cloud.putExternally(account: account, record: blankRecord)
        let good = makeSnippet(name: "Fine", keyword: ";fine")
        let goodRecord = CKRecord(recordType: SnippetRecord.recordType, recordID: cloud.recordID(good.id))
        try SnippetRecord.fill(goodRecord, from: good)
        cloud.putExternally(account: account, record: goodRecord)

        await device.sync()

        let all = try await device.store.allSnippets()
        XCTAssertEqual(all.map(\.id), [good.id])
        let skipped = await device.controller.skippedRemoteRecords
        XCTAssertEqual(skipped, 1)
    }

    func testAServerSideDeleteOfAPendingEditIsPreservedAsACopy() async throws {
        let device = try makeDevice()
        let original = try await device.store.create(makeSnippet(name: "Base", keyword: ";kw"))
        await device.enableSync()
        var edited = original
        edited.name = "Edited while the cloud lost it"
        _ = try await device.store.update(edited)
        cloud.deleteExternally(account: account, id: original.id)
        await device.sync()
        await device.sync()

        let all = try await device.store.allSnippets()
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].name.hasPrefix("Edited while the cloud lost it (conflict copy "))
        XCTAssertEqual(cloud.recordCount(account: account), 1, "the copy was uploaded; the original stays deleted")
    }
}
