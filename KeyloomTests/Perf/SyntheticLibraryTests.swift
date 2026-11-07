import XCTest
@testable import Keyloom

final class SyntheticLibraryTests: StoreTestCase {
    func testGeneratesThousandSnippetsOfAboutOneMebibyte() {
        let snippets = SyntheticLibrary.snippets()
        XCTAssertEqual(snippets.count, 1_000)
        XCTAssertEqual(Set(snippets.map(\.id)).count, 1_000)
        let bytes = snippets.reduce(0) { $0 + $1.template.plainText.utf8.count }
        let target = SyntheticLibrary.defaultTargetBytes
        XCTAssertEqual(Double(bytes), Double(target), accuracy: Double(target) * 0.03, "body bytes \(bytes)")
    }

    func testKeywordsAreUniqueAndNeverShadowEachOther() {
        let snippets = SyntheticLibrary.snippets()
        let keywords = snippets.compactMap(\.keyword)
        XCTAssertEqual(Set(keywords).count, keywords.count)
        XCTAssertEqual(snippets.filter { $0.keyword == nil }.count, 100)
        XCTAssertEqual(keywords, keywords.map(\.precomposedStringWithCanonicalMapping))
        let analysis = KeywordConflicts.analyze(snippets)
        XCTAssertEqual(analysis.conflicts, [])
        XCTAssertEqual(analysis.overlaps, [])
    }

    func testSameSeedGivesIdenticalSnippetsAndAnotherSeedDiffers() {
        XCTAssertEqual(SyntheticLibrary.snippets(), SyntheticLibrary.snippets())
        XCTAssertNotEqual(SyntheticLibrary.snippets(), SyntheticLibrary.snippets(seed: 7))
    }

    func testVariesNamesTagsStylesTokensAndUnicode() {
        let snippets = SyntheticLibrary.snippets()
        let spans = snippets.flatMap(\.template.paragraphs).flatMap(\.runs).flatMap(\.spans)
        var kinds = Set<String>()
        for case .token(let token) in spans {
            switch token.kind {
            case .date: kinds.insert("date")
            case .time: kinds.insert("time")
            case .uuid: kinds.insert("uuid")
            case .clipboard: kinds.insert("clipboard")
            case .argument: kinds.insert("argument")
            case .cursor: kinds.insert("cursor")
            case .unsupported: kinds.insert("unsupported")
            }
        }
        XCTAssertEqual(kinds, ["date", "time", "uuid", "clipboard", "argument", "cursor", "unsupported"])
        XCTAssertGreaterThanOrEqual(Set(snippets.flatMap(\.template.paragraphs).flatMap(\.runs).map(\.style.rawValue)).count, 6)
        XCTAssertEqual(Set(snippets.flatMap(\.template.paragraphs).map(\.kind)), [.plain, .bullet, .numbered])
        XCTAssertTrue(snippets.contains { $0.name.unicodeScalars.contains { !$0.isASCII } })
        XCTAssertTrue(snippets.contains { $0.tags.contains { $0.unicodeScalars.contains { !$0.isASCII } } })
        XCTAssertTrue(snippets.contains { $0.template.plainText.unicodeScalars.contains { !$0.isASCII } })
        XCTAssertGreaterThan(Set(snippets.flatMap(\.tags)).count, 20)
        XCTAssertTrue(snippets.contains { !$0.enabled })
        XCTAssertTrue(snippets.contains(where: \.pinned))
        let noInput = snippets.filter { $0.enabled && $0.keyword != nil && TemplateRenderer.requiredArguments(in: $0.template).isEmpty }
        XCTAssertGreaterThan(noInput.count, 500, "most keyword snippets need no input, as the replacement budget assumes")
    }

    func testWriteStoresEverySnippetThroughStoreAndLibrary() async throws {
        let directory = try makeDirectory().appendingPathComponent("fixture")
        let database = try await SyntheticLibrary.write(to: directory)
        XCTAssertEqual(database.lastPathComponent, SyntheticLibrary.databaseName)

        let library = try await SnippetLibrary(url: database, backupDirectory: directory.appendingPathComponent("backups"))
        let loaded = await library.allSnippets()
        XCTAssertEqual(loaded.count, 1_000)
        XCTAssertEqual(Set(loaded), Set(SyntheticLibrary.snippets()))
        let unreadable = await library.unreadableRecords()
        XCTAssertEqual(unreadable.count, 0)
        await library.close()
    }

    func testWriteRefusesToOverwriteAnExistingLibrary() async throws {
        let directory = try makeDirectory()
        try await SyntheticLibrary.write(to: directory, count: 3, targetBytes: 3_000)
        do {
            try await SyntheticLibrary.write(to: directory, count: 3, targetBytes: 3_000)
            XCTFail("expected libraryAlreadyExists")
        } catch {
            XCTAssertEqual(error as? SyntheticLibrary.WriteError, .libraryAlreadyExists(directory.path))
        }
    }
}

/// Entry point for `scripts/profile/profile.sh`: writes the fixture to `KEYLOOM_FIXTURE_DIR` (with `xcodebuild`
/// pass it as `TEST_RUNNER_KEYLOOM_FIXTURE_DIR`). Skipped when the variable is unset.
final class FixtureWriterTests: XCTestCase {
    func testWriteFixtureToEnvironmentDirectory() async throws {
        guard let path = ProcessInfo.processInfo.environment["KEYLOOM_FIXTURE_DIR"], !path.isEmpty else {
            throw XCTSkip("KEYLOOM_FIXTURE_DIR not set")
        }
        let database = try await SyntheticLibrary.write(to: URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }
}
