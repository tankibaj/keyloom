import XCTest
@testable import Keyloom

/// Symbol icon colors in SQLite: a column added by schema v5, NULL for every row written before it.
final class IconColorStoreTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    private func tinted(_ color: IconColor?, id: UUID? = nil, keyword: String? = ";hi") -> Snippet {
        var snippet = makeSnippet(id: id ?? ids.next(), keyword: keyword)
        snippet.icon = .symbol("envelope", color: color)
        return snippet
    }

    func testColorSurvivesCreateAndReopen() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let created = try await store.create(tinted(.teal))
        await store.close()
        let reopened = try openStore(at: url)
        let loaded = try await reopened.snippet(id: created.id)
        XCTAssertEqual(loaded?.icon, .symbol("envelope", color: .teal))
        XCTAssertEqual(try RawDatabase(url).text("SELECT icon_color FROM snippets"), "teal")
    }

    func testEditingOnlyTheColorIsAnEditThatBumpsTheRevisionAndKeepsHistory() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        var snippet = try await store.create(tinted(.red))
        snippet.icon = .symbol("envelope", color: .blue)
        let updated = try await store.update(snippet)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.icon, .symbol("envelope", color: .blue))
        let history = try await store.revisions(of: snippet.id)
        XCTAssertEqual(history.map(\.snippet.icon), [.symbol("envelope", color: .blue), .symbol("envelope", color: .red)])
        snippet = updated
        snippet.icon = .symbol("envelope", color: nil)
        let cleared = try await store.update(snippet)
        XCTAssertEqual(cleared.icon, .symbol("envelope"))
        XCTAssertEqual(try RawDatabase(url).int("SELECT icon_color IS NULL FROM snippets"), 1)
    }

    func testEmojiRowsNeverCarryAColor() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        var snippet = makeSnippet(id: ids.next())
        snippet.icon = .emoji("👋")
        _ = try await store.create(snippet)
        XCTAssertEqual(try RawDatabase(url).int("SELECT icon_color IS NULL FROM snippets"), 1)
    }

    func testASchemaV4DatabaseGainsTheColumnKeepsItsIconsAndIsBackedUpFirst() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        let old = try openStore(at: url, migrations: [Migrations.v1, Migrations.v2, Migrations.v3, Migrations.v4], backupDirectory: backups)
        await old.close()
        let before = makeSnippet(id: ids.next())
        try RawDatabase(url).insertPreColorSnippet(before)
        XCTAssertEqual(try RawDatabase(url).int("SELECT count(*) FROM pragma_table_info('snippets') WHERE name = 'icon_color'"), 0)

        let store = try openStore(at: url, backupDirectory: backups)
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, Migrations.all.count)
        XCTAssertGreaterThanOrEqual(Migrations.all.count, 5)
        let loaded = try await store.snippet(id: before.id)
        XCTAssertEqual(loaded, before, "an uncolored v4 row reads back identically")
        XCTAssertEqual(loaded?.icon, .symbol("text.bubble", color: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("keyloom-pre-migration-v4-") }, "\(names)")
    }

    func testImportBatchKeepsTheColor() async throws {
        let store = try openStore(at: try databaseURL())
        let result = try await store.importBatch([tinted(.violet)])
        let stored = try XCTUnwrap(result.stored.first)
        XCTAssertEqual(stored.icon, .symbol("envelope", color: .violet))
        let loaded = try await store.snippet(id: stored.id)
        XCTAssertEqual(loaded?.icon, .symbol("envelope", color: .violet))
    }

    func testAnApplyRemoteWithAColorStoresItAndAColorlessUpdateClearsIt() async throws {
        let store = try openStore(at: try databaseURL())
        let account = "icloud:A"
        let id = ids.next()
        var remote = tinted(.pink, id: id)
        _ = try await store.applyRemote(.upsert(remote, systemFields: nil), account: account)
        let first = try await store.snippet(id: id)
        XCTAssertEqual(first?.icon, .symbol("envelope", color: .pink))
        remote.revision += 1
        remote.icon = .symbol("envelope")
        _ = try await store.applyRemote(.upsert(remote, systemFields: nil), account: account)
        let second = try await store.snippet(id: id)
        XCTAssertEqual(second?.icon, .symbol("envelope", color: nil))
    }

    func testAnUnknownStoredColorNameReadsAsNoColorInsteadOfHidingTheSnippet() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let created = try await store.create(tinted(.red))
        try RawDatabase(url).execute("UPDATE snippets SET icon_color = 'chartreuse'")
        let loaded = try await store.snippet(id: created.id)
        XCTAssertEqual(loaded?.icon, .symbol("envelope"))
    }
}
