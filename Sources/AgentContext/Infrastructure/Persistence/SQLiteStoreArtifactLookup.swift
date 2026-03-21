import Foundation
import SQLite3

enum SQLiteStoreArtifactLookup {
    static func findCaptureTimes(
        db: OpaquePointer?,
        appNameLike: String?,
        textTerms: [String],
        start: Date?,
        end: Date?,
        limit: Int
    ) throws -> [Date] {
        let normalizedTerms = textTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedTerms.isEmpty else {
            return []
        }

        var sql = """
            SELECT captured_at
              FROM artifact_perceptions
             WHERE analysis_json IS NOT NULL
        """

        if let appNameLike, !appNameLike.isEmpty {
            sql += " AND lower(app_name) LIKE ?"
        }

        sql += " AND ("
        sql += normalizedTerms.enumerated().map { index, _ in
            let prefix = index == 0 ? "" : " OR "
            return "\(prefix)lower(analysis_json) LIKE ? OR lower(ifnull(window_title, '')) LIKE ? OR lower(ifnull(workspace, '')) LIKE ?"
        }.joined()
        sql += ")"

        if start != nil {
            sql += " AND captured_at >= ?"
        }
        if end != nil {
            sql += " AND captured_at < ?"
        }

        sql += " ORDER BY captured_at DESC LIMIT ?;"

        var statement: OpaquePointer?
        try SQLiteStoreDatabaseSupport.prepare(db: db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let appNameLike, !appNameLike.isEmpty {
            SQLiteStoreDatabaseSupport.bindText(statement, index: bindIndex, value: "%\(appNameLike.lowercased())%")
            bindIndex += 1
        }

        for term in normalizedTerms {
            let like = "%\(term)%"
            SQLiteStoreDatabaseSupport.bindText(statement, index: bindIndex, value: like)
            SQLiteStoreDatabaseSupport.bindText(statement, index: bindIndex + 1, value: like)
            SQLiteStoreDatabaseSupport.bindText(statement, index: bindIndex + 2, value: like)
            bindIndex += 3
        }

        if let start {
            sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970)
            bindIndex += 1
        }
        if let end {
            sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970)
            bindIndex += 1
        }

        sqlite3_bind_int(statement, bindIndex, Int32(max(1, min(limit, 5_000))))

        var output: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
        }
        return output
    }
}
