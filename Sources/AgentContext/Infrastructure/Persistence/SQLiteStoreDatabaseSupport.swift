import Foundation
import SQLite3

enum SQLiteStoreDatabaseSupport {
    static func execute(db: OpaquePointer?, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorPointer)
            throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func prepare(db: OpaquePointer?, sql: String, statement: inout OpaquePointer?) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw NSError(
                domain: "SQLiteStore",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: lastErrorMessage(db: db)]
            )
        }
    }

    static func step(db: OpaquePointer?, statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw NSError(
                domain: "SQLiteStore",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: lastErrorMessage(db: db)]
            )
        }
    }

    static func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    static func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            bindText(statement, index: index, value: value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func lastErrorMessage(db: OpaquePointer?) -> String {
        guard let db else { return "SQLite database unavailable" }
        guard let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
