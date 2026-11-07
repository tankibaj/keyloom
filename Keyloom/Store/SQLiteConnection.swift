import Foundation
import SQLite3

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLValue { .double(value.timeIntervalSince1970) }
    static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString) }
    static func text(orNull value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func date(orNull value: Date?) -> SQLValue { value.map(SQLValue.date) ?? .null }
}

/// One result row, valid only inside the `rows` mapping closure.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
    func string(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }

    func data(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// A single SQLite handle. Not `Sendable`: the owning actor is the only code that touches it, which is
/// what keeps statement reuse and transactions race-free. Errors carry result codes only, never SQL text
/// or bound values, so nothing a user typed can leak through an error or a log.
final class SQLiteConnection {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let busyTimeoutMilliseconds: Int32 = 5_000

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `createIfMissing: false` for files that must already exist (probing, restore sources). Connections are
    /// always read-write: a read-only handle cannot run WAL recovery after a crash, so it could not open a
    /// database that a read-write one opens fine.
    init(path: String, createIfMissing: Bool = true) throws {
        let flags = (createIfMissing ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let code = handle.map(sqlite3_extended_errcode) ?? SQLITE_CANTOPEN
            sqlite3_close(handle)
            throw StoreError.sqlite(code: code, context: "open")
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { close() }

    /// Finalizes every cached statement and closes the handle. Idempotent; the connection is unusable after.
    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        sqlite3_close(handle)
        handle = nil
    }

    // MARK: Statements

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure("exec") }
    }

    /// Runs a write; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        let statement = try prepared(sql, parameters)
        defer { reset(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("step") }
        return Int(sqlite3_changes(handle))
    }

    func rows<T>(_ sql: String, _ parameters: [SQLValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepared(sql, parameters)
        defer { reset(statement) }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try map(SQLiteRow(statement: statement)))
            case SQLITE_DONE: return result
            default: throw failure("step")
            }
        }
    }

    func first<T>(_ sql: String, _ parameters: [SQLValue] = [], map: (SQLiteRow) throws -> T) throws -> T? {
        try rows(sql, parameters, map: map).first
    }

    /// `BEGIN IMMEDIATE` takes the write lock up front, so two connections racing on a constraint
    /// serialize instead of failing at commit. Any failure, including a failing COMMIT, rolls back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // Fails harmlessly when SQLite already rolled the transaction back.
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Pragmas

    var userVersion: Int { get throws { try first("PRAGMA user_version") { $0.int(0) } ?? 0 } }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    // MARK: Backup

    /// Copies this database into `destination` with the SQLite online backup API, which takes a
    /// consistent snapshot even while other connections write.
    func copy(into destination: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw destination.failure("backup")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw StoreError.sqlite(code: step == SQLITE_DONE ? finish : step, context: "backup")
        }
    }

    // MARK: Private

    private func prepared(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &created, nil) == SQLITE_OK,
                  let created else { throw failure("prepare") }
            statements[sql] = created
            statement = created
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .int(let number): code = sqlite3_bind_int64(statement, index, number)
            case .double(let number): code = sqlite3_bind_double(statement, index, number)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                code = data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            guard code == SQLITE_OK else {
                reset(statement)
                throw failure("bind")
            }
        }
        return statement
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func failure(_ context: String) -> StoreError {
        .sqlite(code: handle.map(sqlite3_extended_errcode) ?? SQLITE_ERROR, context: context)
    }
}
