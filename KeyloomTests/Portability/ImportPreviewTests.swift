import XCTest
@testable import Keyloom

final class ImportPreviewTests: StoreTestCase {
    private func preview(_ data: Data, existing: [Snippet] = []) throws -> ImportPreview {
        try ImportPlanner.preview(data, existing: existing, now: clock.now, makeID: { [ids] in ids.next() })
    }

    private func raycast(_ records: [[String: String]]) throws -> Data { try jsonData(records) }

    func testNativeAndRaycastFilesAreToldApartByShape() throws {
        XCTAssertEqual(try preview(try NativeFormat.export([makeSnippet()], exportedAt: clock.now)).format, .keyloom)
        XCTAssertEqual(try preview(try raycast([["name": "A", "text": "t"]])).format, .raycast)
        assertThrows(PortabilityError.notRecognized) { _ = try self.preview(Data("hello".utf8)) }
    }

    func testIdenticalDuplicateIsSkippedEvenWithAnotherIdRevisionAndTimestamps() throws {
        let existing = makeSnippet(id: ids.next(), name: "Greeting", keyword: ";hi", text: "Hello")
        var copy = Snippet(id: ids.next(), name: "Greeting", icon: existing.icon, keyword: ";hi", template: existing.template, createdAt: Date(timeIntervalSince1970: 5))
        copy.revision = 9
        let preview = try preview(try NativeFormat.export([copy], exportedAt: clock.now), existing: [existing])
        XCTAssertEqual(preview.items.map(\.duplicateOf), [existing.id])
        XCTAssertTrue(preview.importable.isEmpty)
    }

    func testRaycastDuplicateComparesNameKeywordAndPlainTextOnly() throws {
        var styled = makeSnippet(id: ids.next(), name: "Sig", keyword: ";sig", text: "Best")
        styled.template = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: .bold, spans: [.literal("Best")])])])
        let preview = try preview(try raycast([["name": "Sig", "text": "Best", "keyword": ";sig"]]), existing: [styled])
        XCTAssertEqual(preview.items.map(\.duplicateOf), [styled.id])
    }

    func testDuplicateInsideTheFileIsSkippedAfterTheFirstCopy() throws {
        let preview = try preview(try raycast([["name": "A", "text": "t", "keyword": ";a"], ["name": "A", "text": "t", "keyword": ";a"]]))
        XCTAssertEqual(preview.items.map { $0.duplicateOf != nil }, [false, true])
        XCTAssertEqual(preview.importable.count, 1)
    }

    func testSameKeywordWithDifferentContentIsKeptDisabledAndNamesTheOwner() throws {
        let existing = makeSnippet(id: ids.next(), name: "Greeting", keyword: ";hi", text: "Hello")
        let preview = try preview(try raycast([["name": "Other", "text": "different", "keyword": ";hi"]]), existing: [existing])
        let item = try XCTUnwrap(preview.items.first)
        XCTAssertEqual(item.conflictsWith, existing.id)
        XCTAssertFalse(item.snippet.enabled)
        XCTAssertEqual(item.snippet.keyword, ";hi", "the keyword is kept so the user can resolve it")
        XCTAssertTrue(item.isImportable)
    }

    func testConflictIsDetectedOnTheComposedFormAndInsideTheFile() throws {
        let existing = makeSnippet(id: ids.next(), name: "Cafe", keyword: "\u{00E9}x", text: "one")
        let preview = try preview(try raycast([
            ["name": "B", "text": "two", "keyword": "e\u{0301}x"],
            ["name": "C", "text": "three", "keyword": ";new"],
            ["name": "D", "text": "four", "keyword": ";new"],
        ]), existing: [existing])
        XCTAssertEqual(preview.items.map(\.snippet.enabled), [false, true, false])
        XCTAssertEqual(preview.items[0].conflictsWith, existing.id)
        XCTAssertEqual(preview.items[2].conflictsWith, preview.items[1].snippet.id)
    }

    func testKeywordOfADisabledOrDeletedSnippetIsNotAConflict() throws {
        let disabled = makeSnippet(id: ids.next(), name: "Off", keyword: ";hi", enabled: false, text: "x")
        let preview = try preview(try raycast([["name": "New", "text": "y", "keyword": ";hi"]]), existing: [disabled])
        XCTAssertNil(preview.items.first?.conflictsWith)
        XCTAssertEqual(preview.items.first?.snippet.enabled, true)
    }

    func testAlreadyDisabledNativeEntryIsNotReportedAsAConflict() throws {
        let existing = makeSnippet(id: ids.next(), name: "A", keyword: ";hi", text: "x")
        var incoming = makeSnippet(id: ids.next(), name: "B", keyword: ";hi", enabled: false, text: "y")
        incoming.enabled = false
        let preview = try preview(try NativeFormat.export([incoming], exportedAt: clock.now), existing: [existing])
        XCTAssertNil(preview.items.first?.conflictsWith)
    }

    func testSameIdWithDifferentContentBecomesACopyWithAFreshId() throws {
        let existing = makeSnippet(id: ids.next(), name: "A", keyword: ";a", text: "x")
        var changed = existing
        changed.name = "A edited"
        changed.revision = 4
        let preview = try preview(try NativeFormat.export([changed], exportedAt: clock.now), existing: [existing])
        let item = try XCTUnwrap(preview.items.first)
        XCTAssertTrue(item.idReassigned)
        XCTAssertNotEqual(item.snippet.id, existing.id)
        XCTAssertEqual(item.snippet.revision, 1)
        XCTAssertEqual(item.conflictsWith, existing.id, "it still shares the enabled keyword")
        XCTAssertFalse(item.snippet.enabled)
    }

    func testUnsupportedTokensAndLiteralFallbackAreReportedPerItem() throws {
        let preview = try preview(try raycast([
            ["name": "U", "text": "{foo} {bar}"], ["name": "L", "text": "if (x) {"], ["name": "P", "text": "plain"],
        ]))
        XCTAssertEqual(preview.items.map(\.unsupportedTokens), [["{foo}", "{bar}"], [], []])
        XCTAssertEqual(preview.items.map(\.templateKeptLiteral), [false, true, false])
    }

    func testMalformedEntriesAreListedAndDoNotBlockTheRest() throws {
        let preview = try preview(Data(#"[{"name": "ok", "text": "t"}, {"name": "x"}, 5]"#.utf8))
        XCTAssertEqual(preview.items.count, 1)
        XCTAssertEqual(preview.malformed.map(\.index), [1, 2])
    }

    func testPreviewIsPureAndRepeatable() throws {
        let existing = [makeSnippet(id: ids.next(), name: "A", keyword: ";a", text: "x")]
        let data = try raycast([["name": "B", "text": "y", "keyword": ";a"]])
        let first = try ImportPlanner.preview(data, existing: existing, now: clock.now, makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! })
        let second = try ImportPlanner.preview(data, existing: existing, now: clock.now, makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! })
        XCTAssertEqual(first, second)
    }

    func testSelectionNarrowsTheSetAndNeverIncludesSkippedDuplicates() throws {
        let existing = makeSnippet(id: ids.next(), name: "A", keyword: ";a", text: "x")
        let preview = try preview(try raycast([
            ["name": "A", "text": "x", "keyword": ";a"], ["name": "B", "text": "y"], ["name": "C", "text": "z"],
        ]), existing: [existing])
        XCTAssertEqual(preview.selected(nil).map(\.index), [1, 2])
        XCTAssertEqual(preview.selected([0, 2]).map(\.index), [2], "a skipped duplicate is not importable even when chosen")
        XCTAssertEqual(preview.selected([]).map(\.index), [])
    }
}
