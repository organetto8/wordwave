import Foundation
import SQLite3

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
}

struct SQLiteError: Error, LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? { "SQLite \(code): \(message)" }
}

/// Minimal read-only SQLite wrapper. Not thread-safe: own it from a single actor.
final class SQLiteConnection {
    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
        }

        func double(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
        }

        func text(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    func query(_ sql: String, _ params: [SQLiteValue] = [], row handler: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            }
        }

        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw lastError() }
            try handler(Row(statement: statement))
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}
