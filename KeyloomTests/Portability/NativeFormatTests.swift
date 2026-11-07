import XCTest
@testable import Keyloom

final class NativeFormatTests: StoreTestCase {
    func testRoundTripKeepsEveryFieldIncludingTheFormattedDocument() throws {
        let original = makeRichSnippet()
        let data = try NativeFormat.export([original], exportedAt: clock.now)
        let decoded = try NativeFormat.decode(data)

        XCTAssertEqual(decoded.malformed, [])
        XCTAssertEqual(decoded.candidates.map(\.snippet), [original], "id, revision, tags, pin, icon, dates, usage and styled document survive")
        XCTAssertEqual(decoded.candidates.first?.snippet.template.paragraphs[1].kind, .bullet)
        XCTAssertEqual(decoded.candidates.first?.snippet.template.paragraphs[0].runs[0].style, [.bold, .italic])
        // Byte-semantic: encoding what was decoded gives the same file.
        XCTAssertEqual(try NativeFormat.export(decoded.candidates.map(\.snippet), exportedAt: clock.now), data)
    }

    func testSymbolColorRoundTripsAndAFileWrittenBeforeColorsStillImports() throws {
        var colored = makeSnippet(id: ids.next(), name: "Tinted", keyword: ";t")
        colored.icon = .symbol("star", color: .salmon)
        let data = try NativeFormat.export([colored], exportedAt: clock.now)
        XCTAssertEqual(try NativeFormat.decode(data).candidates.map(\.snippet.icon), [.symbol("star", color: .salmon)])

        // An export from an earlier build: the icon has no color key.
        let legacy = try nativeFile([colored]) { entries in
            entries[0]["icon"] = ["symbol": ["_0": "star"]]
        }
        let decoded = try NativeFormat.decode(legacy)
        XCTAssertEqual(decoded.malformed, [])
        XCTAssertEqual(decoded.candidates.map(\.snippet.icon), [.symbol("star", color: nil)])
    }

    func testFileCarriesFormatNameAndSchemaVersion() throws {
        let file = try jsonObject(NativeFormat.export([], exportedAt: clock.now))
        XCTAssertEqual(file["format"] as? String, "keyloom-snippets")
        XCTAssertEqual(file["formatVersion"] as? Int, 1)
    }

    func testNewerFormatVersionIsRefusedBeforeTheBodyIsRead() throws {
        let data = try jsonData(["format": "keyloom-snippets", "formatVersion": 2, "snippets": "shape from the future"])
        assertThrows(PortabilityError.unsupportedFormatVersion(found: 2, supported: 1)) { _ = try NativeFormat.decode(data) }
    }

    func testForeignOrBrokenFilesAreRejectedWithTypedErrors() throws {
        assertThrows(PortabilityError.notRecognized) {
            _ = try NativeFormat.decode(try self.jsonData(["format": "something-else", "formatVersion": 1, "snippets": []]))
        }
        assertThrows(PortabilityError.malformedFile) {
            _ = try NativeFormat.decode(Data(#"{"format":"keyloom-snippets","formatVersion":1,"snippets":[{"#.utf8))
        }
        assertThrows(PortabilityError.notRecognized) { _ = try NativeFormat.decode(Data("not json".utf8)) }
        assertThrows(PortabilityError.malformedFile) {
            _ = try NativeFormat.decode(try self.jsonData(["format": "keyloom-snippets", "formatVersion": 1, "snippets": "x"]))
        }
    }

    func testSizeLimitsApplyBeforeAnyEntryIsInterpreted() throws {
        assertThrows(PortabilityError.fileTooLarge(maximumBytes: ImportLimits.maxFileBytes)) {
            _ = try NativeFormat.decode(Data(count: ImportLimits.maxFileBytes + 1))
        }
        let entries = Array(repeating: "{}", count: ImportLimits.maxEntries + 1).joined(separator: ",")
        let crowded = Data(#"{"format":"keyloom-snippets","formatVersion":1,"snippets":[\#(entries)]}"#.utf8)
        assertThrows(PortabilityError.tooManyEntries(maximum: ImportLimits.maxEntries)) { _ = try NativeFormat.decode(crowded) }
    }

    func testMalformedEntriesAreListedByPositionAndGoodOnesKept() throws {
        let good = makeSnippet(id: ids.next(), name: "Good", keyword: ";g")
        let data = try nativeFile([good, good, good, good, good, good]) { entries in
            entries[1] = ["id": "not-a-uuid"]
            entries[2]["name"] = "   "
            var template = entries[3]["template"] as? [String: Any] ?? [:]
            template["schemaVersion"] = 9
            entries[3]["template"] = template
            entries[4]["tags"] = ["a", "a"]
            entries[5]["revision"] = 0
        }
        let decoded = try NativeFormat.decode(data)
        XCTAssertEqual(decoded.candidates.map(\.index), [0])
        XCTAssertEqual(decoded.malformed.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(decoded.malformed.map(\.reason), [
            .invalidStructure, .invalidField("name"), .unsupportedDocumentVersion(found: 9),
            .invalidField("tags"), .invalidField("revision"),
        ])
    }

    func testKeywordIsNormalizedToCanonicalComposedForm() throws {
        let data = try nativeFile([makeSnippet(keyword: ";x")]) { $0[0]["keyword"] = "e\u{0301}x" }
        let decoded = try NativeFormat.decode(data)
        XCTAssertEqual(decoded.candidates.first?.snippet.keyword, "\u{00E9}x")
    }

    func testUnsupportedTokensInANativeDocumentAreFlaggedNotRewritten() throws {
        let decoded = try NativeFormat.decode(NativeFormat.export([makeRichSnippet()], exportedAt: clock.now))
        XCTAssertEqual(decoded.candidates.first?.unsupportedTokens, [#"{date offset="+1d"}"#])
        XCTAssertEqual(decoded.candidates.first?.snippet.template, makeRichSnippet().template)
    }
}
