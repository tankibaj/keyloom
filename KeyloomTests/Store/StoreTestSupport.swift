import Foundation
import SQLite3
import XCTest
@testable import Keyloom

/// Deterministic clock: only moves when a test says so.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Deterministic UUID source: 00000000-0000-0000-0000-000000001001, ...1002, ...
final class SequentialIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int

    init(startingAt start: Int = 1_000) { counter = start }

    func next() -> UUID {
        let value = lock.withLock { () -> Int in counter += 1; return counter }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

/// Independent view of a database file, so assertions do not go through the code under test.
final class RawDatabase {
    private var handle: OpaquePointer?

    struct RawError: Error { let message: String }

    init(_ url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            throw RawError(message: "open failed")
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw RawError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func int(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RawError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw RawError(message: "no row") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func text(_ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RawError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            throw RawError(message: "no row")
        }
        return String(cString: cString)
    }

    func count(_ table: String) throws -> Int { try int("SELECT count(*) FROM \(table)") }
    var userVersion: Int { get throws { try int("PRAGMA user_version") } }
}

class StoreTestCase: XCTestCase {
    let clock = TestClock()
    let ids = SequentialIDs()

    /// A fresh temp directory, removed after the test.
    func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyloom-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Backups go to `backups/` next to the database unless a test says otherwise.
    func openStore(at url: URL, migrations: [Migration] = Migrations.all, syncAccount: String = "local",
                   backupDirectory: URL? = nil) throws -> SnippetStore {
        try SnippetStore(url: url,
                         backupDirectory: backupDirectory ?? url.deletingLastPathComponent().appendingPathComponent("backups"),
                         syncAccount: syncAccount, migrations: migrations,
                         now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
    }

    func makeSnippet(id: UUID = UUID(), name: String = "Greeting", keyword: String? = ";hi", enabled: Bool = true,
                     tags: [String] = [], text: String = "Hello") -> Snippet {
        Snippet(id: id, name: name, icon: .symbol("text.bubble"), keyword: keyword, enabled: enabled, tags: tags,
                template: Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal(text)])])]),
                createdAt: clock.now)
    }

    func assertThrows(_ expected: StoreError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StoreError, expected, file: file, line: line)
        }
    }
}
