import XCTest
@testable import Keyloom

@MainActor
class BackupsTestCase: LibraryUITestCase {
    var library: SnippetLibrary!
    var snapshots: SnapshotManager!
    var snapshotDirectory: URL!
    var model: SyncBackupsModel!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUp() async throws {
        library = try await openTestLibrary()
        snapshotDirectory = try makeDirectory().appendingPathComponent("snapshots")
        snapshots = SnapshotManager(directory: snapshotDirectory, now: { [clock] in clock.now }, calendar: utc)
        model = SyncBackupsModel(library: library, snapshots: snapshots, now: { [clock] in clock.now }, calendar: utc)
    }

    func raycastFile(_ records: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: records) }
}

final class ImportPreviewMappingTests: BackupsTestCase {
    private func previewOfMixedFile() async throws -> ImportPreviewSummary {
        try await seed(library, "Alpha", keyword: ";a", body: "A")
        try await model.loadImport(data: raycastFile([
            ["name": "Alpha", "text": "A", "keyword": ";a"],                       // identical: duplicate
            ["name": "Other", "text": "B", "keyword": ";a"],                       // keyword taken: conflict
            ["name": "Odd", "text": "Hi {foo} and {bar}", "keyword": ";odd"],      // unsupported tokens
            ["name": "Fine", "text": "ok"],                                        // plain new
            ["unexpected": 5],                                                     // malformed entry
        ]))
        return try XCTUnwrap(model.importPreview)
    }

    func testPreviewNamesDuplicatesConflictsUnsupportedTokensAndMalformedEntries() async throws {
        let summary = try await previewOfMixedFile()
        XCTAssertEqual(summary.rows.map(\.name), ["Alpha", "Other", "Odd", "Fine"])
        XCTAssertEqual(summary.rows.map(\.status), [.duplicate, .keywordConflict, .new, .new])
        XCTAssertEqual(summary.duplicateCount, 1)
        XCTAssertEqual(summary.conflictCount, 1)
        XCTAssertEqual(summary.newCount, 2)
        XCTAssertEqual(summary.unsupportedTokens, ["{foo}", "{bar}"])
        XCTAssertEqual(summary.malformedCount, 1)
        XCTAssertEqual(summary.format, .raycast)
    }

    func testDuplicatesCannotBeSelectedAndEverythingElseStartsSelected() async throws {
        let summary = try await previewOfMixedFile()
        let selectable = summary.rows.filter(\.isSelectable).map(\.name)
        XCTAssertEqual(selectable, ["Other", "Odd", "Fine"])
        XCTAssertEqual(model.selectedImportRows, Set(summary.rows.filter(\.isSelectable).map(\.index)))
    }

    func testCommitImportsOnlyTheSelectedRowsKeepsConflictsDisabledAndSavesASafeguardFirst() async throws {
        let summary = try await previewOfMixedFile()
        let fine = try XCTUnwrap(summary.rows.first { $0.name == "Fine" })
        model.toggleImportRow(fine.index)
        await model.commitImport()
        let names = await library.allSnippets().map(\.name).sorted()
        XCTAssertEqual(names, ["Alpha", "Odd", "Other"])
        let other = await library.allSnippets().first { $0.name == "Other" }
        XCTAssertEqual(other?.enabled, false, "A conflicting keyword imports disabled")
        XCTAssertNil(model.importPreview, "The sheet closes")
        XCTAssertTrue(model.message?.contains("Imported 2") == true, model.message ?? "nil")
        XCTAssertTrue(model.message?.contains("1 off") == true, model.message ?? "nil")
        let kinds = try await snapshots.list().map(\.kind)
        XCTAssertTrue(kinds.contains(.preImport))
    }

    func testCancellingThePreviewWritesNothing() async throws {
        _ = try await previewOfMixedFile()
        model.cancelImport()
        XCTAssertNil(model.importPreview)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 1)
        let listed = try await snapshots.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testAFileThatIsNotAnExportIsRefusedWholeWithAReason() async throws {
        try await seed(library, "Alpha")
        await model.loadImport(data: Data("hello".utf8))
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.errorMessage, PortabilityError.notRecognized.errorDescription)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 1)
    }

    func testAnOversizedFileIsRefusedBeforeItIsRead() async throws {
        let url = try makeDirectory().appendingPathComponent("huge.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImportLimits.maxFileBytes + 1))
        try handle.close()
        await model.loadImport(url: url)
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.errorMessage, PortabilityError.fileTooLarge(maximumBytes: ImportLimits.maxFileBytes).errorDescription)
    }

    func testAFileFromAnotherKeyloomPreviewsAsNewSnippets() async throws {
        let other = try await openTestLibrary()
        try await seed(other, "From elsewhere", keyword: ";x", body: "Body")
        let exported = try await other.exportNative()
        await model.loadImport(data: exported)
        XCTAssertEqual(model.importPreview?.format, .keyloom)
        XCTAssertEqual(model.importPreview?.rows.map(\.status), [.new])
    }
}

final class ExportTests: BackupsTestCase {
    func testNativeExportIsNamedByDateAndRoundTripsThroughImport() async throws {
        try await seed(library, "Alpha", keyword: ";a", tags: ["t"], body: "A", pinned: true)
        let file = try required(await model.exportNative())
        XCTAssertEqual(file.filename, "Keyloom Snippets 2023-11-14.json")
        let fresh = try await openTestLibrary()
        let freshModel = SyncBackupsModel(library: fresh, snapshots: snapshots, now: { [clock] in clock.now }, calendar: utc)
        await freshModel.loadImport(data: file.data)
        XCTAssertEqual(freshModel.importPreview?.rows.map(\.name), ["Alpha"])
        await freshModel.commitImport()
        let restored = await fresh.allSnippets()
        XCTAssertEqual(restored.map(\.keyword), [";a"])
        XCTAssertEqual(restored.map(\.pinned), [true])
    }

    func testRaycastExportListsWhatItDropsBeforeSaving() async throws {
        _ = try await library.create(makeRichSnippet())
        try await seed(library, "Plain", keyword: ";p", body: "plain")
        let plan = try required(await model.prepareRaycastExport())
        XCTAssertEqual(plan.file.filename, "Keyloom Snippets (Raycast) 2023-11-14.json")
        XCTAssertEqual(plan.lossCounts[.textStyles], 1)
        XCTAssertEqual(plan.lossCounts[.listFormatting], 1)
        XCTAssertEqual(plan.lossCounts[.tags], 1)
        XCTAssertEqual(plan.lossCounts[.pinned], 1)
        XCTAssertEqual(plan.lossCounts[.disabled], 1)
        XCTAssertTrue(plan.hasLoss)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.file.data) as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
    }

    func testRaycastExportOfPlainSnippetsHasNoLossWarning() async throws {
        try await seed(library, "Plain", keyword: ";p", body: "plain")
        let plan = try required(await model.prepareRaycastExport())
        XCTAssertFalse(plan.hasLoss)
    }
}

final class SnapshotListTests: BackupsTestCase {
    func testBackUpNowListsADailySnapshotAndSaysWhenNothingChanged() async throws {
        try await seed(library, "Alpha")
        await model.backUpNow()
        XCTAssertEqual(model.snapshotRows.map(\.kind), [.daily])
        XCTAssertNotNil(model.message)
        let first = model.message
        await model.backUpNow()
        XCTAssertEqual(model.snapshotRows.count, 1)
        XCTAssertNotEqual(model.message, first, "A second press explains that nothing changed")
        XCTAssertTrue(model.message?.contains("nothing has changed") == true, model.message ?? "nil")
    }

    func testRowsAreNewestFirstAndLabelledByKind() async throws {
        try await seed(library, "Alpha")
        await model.backUpNow()
        clock.advance(by: 86_400)
        try await seed(library, "Beta")
        await model.backUpNow()
        XCTAssertEqual(model.snapshotRows.count, 2)
        XCTAssertGreaterThan(model.snapshotRows[0].createdAt, model.snapshotRows[1].createdAt)
        XCTAssertEqual(model.snapshotRows.first?.title, "Daily")
    }

    func testRestoreAsksFirstThenRestoresAndKeepsASafeguardOfTheCurrentLibrary() async throws {
        let alpha = try await seed(library, "Alpha")
        await model.backUpNow()
        try await seed(library, "Beta")
        let row = try XCTUnwrap(model.snapshotRows.first)

        model.requestRestore(row)
        XCTAssertEqual(model.pendingRestore, row)
        var names = await library.allSnippets().map(\.name)
        XCTAssertEqual(names.sorted(), ["Alpha", "Beta"], "Asking changes nothing")

        await model.confirmRestore()
        names = await library.allSnippets().map(\.name)
        XCTAssertEqual(names, ["Alpha"])
        XCTAssertNil(model.pendingRestore)
        XCTAssertTrue(model.snapshotRows.map(\.kind).contains(.preRestore))
        XCTAssertTrue(model.message?.contains("1 removed") == true, model.message ?? "nil")
        let restored = await library.snippet(id: alpha.id)
        XCTAssertNotNil(restored)
    }

    func testCancellingTheConfirmationLeavesTheLibraryAlone() async throws {
        try await seed(library, "Alpha")
        await model.backUpNow()
        try await seed(library, "Beta")
        model.requestRestore(try XCTUnwrap(model.snapshotRows.first))
        model.cancelRestore()
        XCTAssertNil(model.pendingRestore)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 2)
    }

    func testADamagedSnapshotIsRefusedAndTheLibraryIsUntouched() async throws {
        try await seed(library, "Alpha")
        await model.backUpNow()
        try await seed(library, "Beta")
        let row = try XCTUnwrap(model.snapshotRows.first)
        try Data("{\"garbage\":".utf8).write(to: row.info.url)
        model.requestRestore(row)
        await model.confirmRestore()
        XCTAssertEqual(model.errorMessage, SnapshotError.corrupt.errorDescription)
        let count = await library.allSnippets().count
        XCTAssertEqual(count, 2)
    }

    func testAnUnwritableSnapshotFolderIsReportedNotSwallowed() async throws {
        let blocker = try makeDirectory().appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let blocked = SnapshotManager(directory: blocker.appendingPathComponent("inside"), now: { [clock] in clock.now }, calendar: utc)
        let failing = SyncBackupsModel(library: library, snapshots: blocked, now: { [clock] in clock.now }, calendar: utc)
        try await seed(library, "Alpha")
        await failing.backUpNow()
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertTrue(failing.snapshotRows.isEmpty)
    }
}
