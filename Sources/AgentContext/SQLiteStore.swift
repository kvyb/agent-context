import Foundation
import SQLite3

struct TimelineSlice: Sendable {
    let startTime: Date
    let endTime: Date
    let appName: String
    let bundleID: String?
    let project: String?
}

struct StoredEvidenceRecord: Sendable {
    let metadata: ArtifactMetadata
    let analysis: ArtifactAnalysis?
}

struct MemoryRecord: Sendable {
    let occurredAt: Date
    let scope: String
    let appName: String?
    let project: String?
    let summary: String
    let entities: [String]
}

struct PurgedArtifactBatch: Sendable {
    let kind: ArtifactKind
    let deletedRows: Int
    let deletedPaths: [String]
}

actor SQLiteStore {
    private let databaseURL: URL
    private var db: OpaquePointer?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try Self.openDatabase(at: databaseURL)
        try Self.migrate(db: db)
    }

    private static func openDatabase(at databaseURL: URL) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        if sqlite3_open(databaseURL.path, &handle) != SQLITE_OK {
            defer { if handle != nil { sqlite3_close(handle) } }
            throw NSError(
                domain: "SQLiteStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open database at \(databaseURL.path)"]
            )
        }
        sqlite3_busy_timeout(handle, 5_000)
        return handle
    }

    private static func migrate(db: OpaquePointer?) throws {
        let statements = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            """
            CREATE TABLE IF NOT EXISTS intervals (
                id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                app_name TEXT NOT NULL,
                bundle_id TEXT,
                pid INTEGER NOT NULL,
                window_title TEXT,
                document_path TEXT,
                window_url TEXT,
                workspace TEXT,
                project TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_intervals_time ON intervals(start_time, end_time);",
            """
            CREATE TABLE IF NOT EXISTS evidence (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                artifact_path TEXT NOT NULL,
                captured_at REAL NOT NULL,
                app_name TEXT NOT NULL,
                bundle_id TEXT,
                pid INTEGER NOT NULL,
                window_title TEXT,
                document_path TEXT,
                window_url TEXT,
                workspace TEXT,
                project TEXT,
                interval_id TEXT,
                capture_reason TEXT,
                sequence_in_interval INTEGER,
                analysis_json TEXT,
                llm_model TEXT,
                llm_input_tokens INTEGER DEFAULT 0,
                llm_output_tokens INTEGER DEFAULT 0,
                llm_audio_tokens INTEGER DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending',
                error_message TEXT,
                FOREIGN KEY(interval_id) REFERENCES intervals(id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_evidence_captured_at ON evidence(captured_at);",
            """
            CREATE TABLE IF NOT EXISTS interval_summaries (
                id TEXT PRIMARY KEY,
                bucket_start REAL NOT NULL,
                bucket_end REAL NOT NULL,
                app_name TEXT NOT NULL,
                bundle_id TEXT,
                summary TEXT NOT NULL,
                entities_json TEXT,
                insufficient_evidence INTEGER NOT NULL,
                llm_model TEXT,
                llm_input_tokens INTEGER DEFAULT 0,
                llm_output_tokens INTEGER DEFAULT 0,
                llm_audio_tokens INTEGER DEFAULT 0,
                finalized_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_interval_summaries_bucket ON interval_summaries(bucket_start, bucket_end);",
            """
            CREATE TABLE IF NOT EXISTS hour_summaries (
                id TEXT PRIMARY KEY,
                hour_start REAL NOT NULL,
                hour_end REAL NOT NULL,
                summary TEXT NOT NULL,
                llm_model TEXT,
                llm_input_tokens INTEGER DEFAULT 0,
                llm_output_tokens INTEGER DEFAULT 0,
                llm_audio_tokens INTEGER DEFAULT 0,
                finalized_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_hour_summaries_hour ON hour_summaries(hour_start, hour_end);",
            """
            CREATE TABLE IF NOT EXISTS llm_usage_events (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                audio_tokens INTEGER NOT NULL,
                estimated_cost_usd REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_llm_usage_created_at ON llm_usage_events(created_at);",
            """
            CREATE TABLE IF NOT EXISTS mem0_memory (
                id TEXT PRIMARY KEY,
                occurred_at REAL NOT NULL,
                scope TEXT NOT NULL,
                app_name TEXT,
                project TEXT,
                summary TEXT NOT NULL,
                entities_json TEXT,
                payload_json TEXT NOT NULL,
                mem0_status TEXT NOT NULL,
                mem0_response_json TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_mem0_memory_occurred_at ON mem0_memory(occurred_at);",
            """
            CREATE TABLE IF NOT EXISTS task_segments (
                id TEXT PRIMARY KEY,
                scope TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                occurred_at REAL NOT NULL,
                app_name TEXT,
                bundle_id TEXT,
                project TEXT,
                workspace TEXT,
                repo TEXT,
                document TEXT,
                url TEXT,
                task TEXT NOT NULL,
                issue_or_goal TEXT,
                actions_json TEXT NOT NULL,
                outcome TEXT,
                next_step TEXT,
                status TEXT NOT NULL,
                confidence REAL NOT NULL,
                evidence_refs_json TEXT NOT NULL,
                entities_json TEXT NOT NULL,
                summary TEXT NOT NULL,
                source_summary_id TEXT,
                prompt_version TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_task_segments_time ON task_segments(occurred_at);",
            "CREATE INDEX IF NOT EXISTS idx_task_segments_status ON task_segments(status);",
            "CREATE INDEX IF NOT EXISTS idx_task_segments_app_project ON task_segments(app_name, project);",
            """
            CREATE TABLE IF NOT EXISTS finalized_interval_buckets (
                bucket_start REAL PRIMARY KEY,
                finalized_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS finalized_hours (
                hour_start REAL PRIMARY KEY,
                finalized_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS pending_interval_buckets (
                bucket_start REAL PRIMARY KEY,
                next_attempt_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_interval_due ON pending_interval_buckets(next_attempt_at);",
            """
            CREATE TABLE IF NOT EXISTS pending_hours (
                hour_start REAL PRIMARY KEY,
                next_attempt_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_hours_due ON pending_hours(next_attempt_at);",
            "CREATE INDEX IF NOT EXISTS idx_mem0_memory_status_updated ON mem0_memory(mem0_status, updated_at);"
        ]

        for sql in statements {
            var errorPointer: UnsafeMutablePointer<Int8>?
            let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
            guard code == SQLITE_OK else {
                let message = errorPointer.map { String(cString: $0) } ?? "SQLite migration error"
                sqlite3_free(errorPointer)
                throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    func insertInterval(_ interval: ActivityInterval) throws {
        let sql = """
            INSERT OR REPLACE INTO intervals(
                id, start_time, end_time, app_name, bundle_id, pid,
                window_title, document_path, window_url, workspace, project
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: interval.id)
        sqlite3_bind_double(statement, 2, interval.startTime.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.endTime.timeIntervalSince1970)
        bindText(statement, index: 4, value: interval.app.appName)
        bindOptionalText(statement, index: 5, value: interval.app.bundleID)
        sqlite3_bind_int(statement, 6, interval.app.pid)
        bindOptionalText(statement, index: 7, value: interval.window.title)
        bindOptionalText(statement, index: 8, value: interval.window.documentPath)
        bindOptionalText(statement, index: 9, value: interval.window.url)
        bindOptionalText(statement, index: 10, value: interval.window.workspace)
        bindOptionalText(statement, index: 11, value: interval.window.project)

        try step(statement)
    }

    func insertEvidence(_ metadata: ArtifactMetadata) throws {
        let sql = """
            INSERT OR REPLACE INTO evidence(
                id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
                window_title, document_path, window_url, workspace, project,
                interval_id, capture_reason, sequence_in_interval, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending');
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: metadata.id)
        bindText(statement, index: 2, value: metadata.kind.rawValue)
        bindText(statement, index: 3, value: metadata.path)
        sqlite3_bind_double(statement, 4, metadata.capturedAt.timeIntervalSince1970)
        bindText(statement, index: 5, value: metadata.app.appName)
        bindOptionalText(statement, index: 6, value: metadata.app.bundleID)
        sqlite3_bind_int(statement, 7, metadata.app.pid)
        bindOptionalText(statement, index: 8, value: metadata.window.title)
        bindOptionalText(statement, index: 9, value: metadata.window.documentPath)
        bindOptionalText(statement, index: 10, value: metadata.window.url)
        bindOptionalText(statement, index: 11, value: metadata.window.workspace)
        bindOptionalText(statement, index: 12, value: metadata.window.project)
        bindOptionalText(statement, index: 13, value: metadata.intervalID)
        bindText(statement, index: 14, value: metadata.captureReason)
        sqlite3_bind_int(statement, 15, Int32(metadata.sequenceInInterval))

        try step(statement)
    }

    func markEvidenceAnalyzed(
        evidenceID: String,
        analysis: ArtifactAnalysis,
        usage: LLMUsageEvent?,
        model: String?
    ) throws {
        let analysisData = try jsonEncoder.encode(analysis)
        let analysisJSON = String(data: analysisData, encoding: .utf8) ?? "{}"

        let sql = """
            UPDATE evidence
               SET analysis_json = ?,
                   llm_model = ?,
                   llm_input_tokens = ?,
                   llm_output_tokens = ?,
                   llm_audio_tokens = ?,
                   status = 'analyzed',
                   error_message = NULL
             WHERE id = ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: analysisJSON)
        bindOptionalText(statement, index: 2, value: model)
        sqlite3_bind_int(statement, 3, Int32(usage?.inputTokens ?? 0))
        sqlite3_bind_int(statement, 4, Int32(usage?.outputTokens ?? 0))
        sqlite3_bind_int(statement, 5, Int32(usage?.audioTokens ?? 0))
        bindText(statement, index: 6, value: evidenceID)
        try step(statement)

        if let usage {
            try appendUsageEvent(usage)
        }
    }

    func markEvidenceFailed(evidenceID: String, errorMessage: String) throws {
        let sql = """
            UPDATE evidence
               SET status = 'failed',
                   error_message = ?
             WHERE id = ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: errorMessage)
        bindText(statement, index: 2, value: evidenceID)
        try step(statement)
    }

    func deleteEvidence(evidenceID: String) throws {
        let sql = "DELETE FROM evidence WHERE id = ?;"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: evidenceID)
        try step(statement)
    }

    func listEvidenceForBackfill(limit: Int) throws -> [ArtifactMetadata] {
        let sql = """
            SELECT id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
                   window_title, document_path, window_url, workspace, project,
                   interval_id, capture_reason, sequence_in_interval
              FROM evidence
             WHERE status != 'analyzed'
             ORDER BY captured_at ASC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))

        var output: [ArtifactMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(
                ArtifactMetadata(
                    id: string(statement, column: 0) ?? UUID().uuidString,
                    kind: ArtifactKind(rawValue: string(statement, column: 1) ?? "screenshot") ?? .screenshot,
                    path: string(statement, column: 2) ?? "",
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    app: AppDescriptor(
                        appName: string(statement, column: 4) ?? "Unknown",
                        bundleID: string(statement, column: 5),
                        pid: sqlite3_column_int(statement, 6)
                    ),
                    window: WindowContext(
                        title: string(statement, column: 7),
                        documentPath: string(statement, column: 8),
                        url: string(statement, column: 9),
                        workspace: string(statement, column: 10),
                        project: string(statement, column: 11)
                    ),
                    intervalID: string(statement, column: 12),
                    captureReason: string(statement, column: 13) ?? "unknown",
                    sequenceInInterval: Int(sqlite3_column_int(statement, 14))
                )
            )
        }

        return output
    }

    func evidenceDetails(forIntervalID intervalID: String) throws -> [EvidenceDetailItem] {
        let sql = """
            SELECT id, captured_at, kind, app_name, analysis_json
              FROM evidence
             WHERE interval_id = ?
             ORDER BY captured_at ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: intervalID)

        var output: [EvidenceDetailItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = string(statement, column: 0) ?? UUID().uuidString
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let kind = ArtifactKind(rawValue: string(statement, column: 2) ?? "screenshot") ?? .screenshot
            let appName = string(statement, column: 3) ?? "Unknown"
            let analysis = parseAnalysisJSON(string(statement, column: 4))

            output.append(
                EvidenceDetailItem(
                    id: id,
                    timestamp: timestamp,
                    kind: kind,
                    appName: appName,
                    description: analysis?.description ?? (analysis?.summary ?? "Pending analysis"),
                    problem: analysis?.problem,
                    success: analysis?.success,
                    userContribution: analysis?.userContribution,
                    suggestionOrDecision: analysis?.suggestionOrDecision,
                    status: analysis?.status ?? .none,
                    confidence: analysis?.confidence ?? 0,
                    summary: analysis?.summary ?? "Pending analysis",
                    transcript: analysis?.transcript,
                    entities: analysis?.entities ?? [],
                    project: analysis?.project,
                    workspace: analysis?.workspace,
                    task: analysis?.task,
                    evidence: analysis?.evidence ?? []
                )
            )
        }

        return output
    }

    func evidenceDetails(
        forHourStart hourStart: Date,
        hourEnd: Date,
        appName: String,
        bundleID: String?
    ) throws -> [EvidenceDetailItem] {
        let sql = """
            SELECT id, captured_at, kind, app_name, analysis_json
              FROM evidence
             WHERE captured_at >= ? AND captured_at < ?
               AND app_name = ?
               AND ((bundle_id IS NULL AND ? IS NULL) OR bundle_id = ?)
             ORDER BY captured_at ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, hourEnd.timeIntervalSince1970)
        bindText(statement, index: 3, value: appName)
        bindOptionalText(statement, index: 4, value: bundleID)
        bindOptionalText(statement, index: 5, value: bundleID)

        var output: [EvidenceDetailItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = string(statement, column: 0) ?? UUID().uuidString
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let kind = ArtifactKind(rawValue: string(statement, column: 2) ?? "screenshot") ?? .screenshot
            let appName = string(statement, column: 3) ?? "Unknown"
            let analysis = parseAnalysisJSON(string(statement, column: 4))

            output.append(
                EvidenceDetailItem(
                    id: id,
                    timestamp: timestamp,
                    kind: kind,
                    appName: appName,
                    description: analysis?.description ?? (analysis?.summary ?? "Pending analysis"),
                    problem: analysis?.problem,
                    success: analysis?.success,
                    userContribution: analysis?.userContribution,
                    suggestionOrDecision: analysis?.suggestionOrDecision,
                    status: analysis?.status ?? .none,
                    confidence: analysis?.confidence ?? 0,
                    summary: analysis?.summary ?? "Pending analysis",
                    transcript: analysis?.transcript,
                    entities: analysis?.entities ?? [],
                    project: analysis?.project,
                    workspace: analysis?.workspace,
                    task: analysis?.task,
                    evidence: analysis?.evidence ?? []
                )
            )
        }

        return output
    }

    func fetchArtifactMetadata(id: String) throws -> ArtifactMetadata? {
        let sql = """
            SELECT id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
                   window_title, document_path, window_url, workspace, project,
                   interval_id, capture_reason, sequence_in_interval
              FROM evidence
             WHERE id = ?
             LIMIT 1;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return ArtifactMetadata(
            id: string(statement, column: 0) ?? id,
            kind: ArtifactKind(rawValue: string(statement, column: 1) ?? "screenshot") ?? .screenshot,
            path: string(statement, column: 2) ?? "",
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            app: AppDescriptor(
                appName: string(statement, column: 4) ?? "Unknown",
                bundleID: string(statement, column: 5),
                pid: sqlite3_column_int(statement, 6)
            ),
            window: WindowContext(
                title: string(statement, column: 7),
                documentPath: string(statement, column: 8),
                url: string(statement, column: 9),
                workspace: string(statement, column: 10),
                project: string(statement, column: 11)
            ),
            intervalID: string(statement, column: 12),
            captureReason: string(statement, column: 13) ?? "unknown",
            sequenceInInterval: Int(sqlite3_column_int(statement, 14))
        )
    }

    func purgeEvidence(kind: ArtifactKind, capturedBefore cutoff: Date, limit: Int) throws -> PurgedArtifactBatch {
        let candidates = try listEvidencePurgeCandidates(
            kind: kind,
            capturedBefore: cutoff,
            limit: min(2_000, max(1, limit))
        )
        guard !candidates.isEmpty else {
            return PurgedArtifactBatch(kind: kind, deletedRows: 0, deletedPaths: [])
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let deleteSQL = "DELETE FROM evidence WHERE id = ?;"
            var deleteStatement: OpaquePointer?
            try prepare(deleteSQL, statement: &deleteStatement)
            defer { sqlite3_finalize(deleteStatement) }

            for candidate in candidates {
                bindText(deleteStatement, index: 1, value: candidate.id)
                try step(deleteStatement)
                sqlite3_reset(deleteStatement)
                sqlite3_clear_bindings(deleteStatement)
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        return PurgedArtifactBatch(
            kind: kind,
            deletedRows: candidates.count,
            deletedPaths: candidates.map(\.path)
        )
    }

    func listIntervals(forDay date: Date, calendar: Calendar) throws -> [ActivityInterval] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)

        let sql = """
            SELECT id, start_time, end_time, app_name, bundle_id, pid,
                   window_title, document_path, window_url, workspace, project
              FROM intervals
             WHERE end_time > ? AND start_time < ?
             ORDER BY start_time ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, dayEnd.timeIntervalSince1970)

        var rows: [ActivityInterval] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                ActivityInterval(
                    id: string(statement, column: 0) ?? UUID().uuidString,
                    startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    app: AppDescriptor(
                        appName: string(statement, column: 3) ?? "Unknown",
                        bundleID: string(statement, column: 4),
                        pid: sqlite3_column_int(statement, 5)
                    ),
                    window: WindowContext(
                        title: string(statement, column: 6),
                        documentPath: string(statement, column: 7),
                        url: string(statement, column: 8),
                        workspace: string(statement, column: 9),
                        project: string(statement, column: 10)
                    )
                )
            )
        }

        return rows
    }

    func appDurationsForBucket(start: Date, end: Date) throws -> [(appName: String, bundleID: String?, seconds: TimeInterval)] {
        let sql = """
            SELECT app_name,
                   bundle_id,
                   SUM(MAX(0, MIN(end_time, ?) - MAX(start_time, ?))) AS overlap_seconds
              FROM intervals
             WHERE end_time > ? AND start_time < ?
          GROUP BY app_name, bundle_id
            HAVING overlap_seconds > 0.5
          ORDER BY overlap_seconds DESC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        let bucketEnd = end.timeIntervalSince1970
        let bucketStart = start.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, bucketEnd)
        sqlite3_bind_double(statement, 2, bucketStart)
        sqlite3_bind_double(statement, 3, bucketStart)
        sqlite3_bind_double(statement, 4, bucketEnd)

        var results: [(String, String?, TimeInterval)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let appName = string(statement, column: 0) ?? "Unknown"
            let bundleID = string(statement, column: 1)
            let seconds = sqlite3_column_double(statement, 2)
            results.append((appName, bundleID, seconds))
        }

        return results
    }

    func evidenceForBucket(start: Date, end: Date, appName: String, bundleID: String?) throws -> [StoredEvidenceRecord] {
        let sql = """
            SELECT id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
                   window_title, document_path, window_url, workspace, project,
                   interval_id, capture_reason, sequence_in_interval, analysis_json
              FROM evidence
             WHERE captured_at >= ? AND captured_at < ?
               AND app_name = ?
               AND ((bundle_id IS NULL AND ? IS NULL) OR bundle_id = ?)
             ORDER BY captured_at ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        bindText(statement, index: 3, value: appName)
        bindOptionalText(statement, index: 4, value: bundleID)
        bindOptionalText(statement, index: 5, value: bundleID)

        var output: [StoredEvidenceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = string(statement, column: 0) ?? UUID().uuidString
            let kind = ArtifactKind(rawValue: string(statement, column: 1) ?? "screenshot") ?? .screenshot
            let analysisJSON = string(statement, column: 15)
            let analysis: ArtifactAnalysis?
            if let analysisJSON,
               let data = analysisJSON.data(using: .utf8) {
                analysis = try? jsonDecoder.decode(ArtifactAnalysis.self, from: data)
            } else {
                analysis = nil
            }

            let metadata = ArtifactMetadata(
                id: id,
                kind: kind,
                path: string(statement, column: 2) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                app: AppDescriptor(
                    appName: string(statement, column: 4) ?? appName,
                    bundleID: string(statement, column: 5),
                    pid: sqlite3_column_int(statement, 6)
                ),
                window: WindowContext(
                    title: string(statement, column: 7),
                    documentPath: string(statement, column: 8),
                    url: string(statement, column: 9),
                    workspace: string(statement, column: 10),
                    project: string(statement, column: 11)
                ),
                intervalID: string(statement, column: 12),
                captureReason: string(statement, column: 13) ?? "unknown",
                sequenceInInterval: Int(sqlite3_column_int(statement, 14))
            )

            output.append(StoredEvidenceRecord(metadata: metadata, analysis: analysis))
        }

        return output
    }

    func timelineForBucket(start: Date, end: Date) throws -> [TimelineSlice] {
        let sql = """
            SELECT start_time, end_time, app_name, bundle_id, project
              FROM intervals
             WHERE end_time > ? AND start_time < ?
             ORDER BY start_time ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)

        var rows: [TimelineSlice] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sliceStart = max(start.timeIntervalSince1970, sqlite3_column_double(statement, 0))
            let sliceEnd = min(end.timeIntervalSince1970, sqlite3_column_double(statement, 1))
            guard sliceEnd > sliceStart else { continue }

            rows.append(
                TimelineSlice(
                    startTime: Date(timeIntervalSince1970: sliceStart),
                    endTime: Date(timeIntervalSince1970: sliceEnd),
                    appName: string(statement, column: 2) ?? "Unknown",
                    bundleID: string(statement, column: 3),
                    project: string(statement, column: 4)
                )
            )
        }

        return rows
    }

    func saveIntervalSummary(
        _ summary: IntervalSummary,
        usage: LLMUsageEvent?,
        model: String?
    ) throws {
        let entitiesData = try jsonEncoder.encode(summary.entities)
        let entitiesJSON = String(data: entitiesData, encoding: .utf8) ?? "[]"

        let sql = """
            INSERT OR REPLACE INTO interval_summaries(
                id, bucket_start, bucket_end, app_name, bundle_id, summary,
                entities_json, insufficient_evidence, llm_model,
                llm_input_tokens, llm_output_tokens, llm_audio_tokens,
                finalized_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: summary.id)
        sqlite3_bind_double(statement, 2, summary.bucketStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, summary.bucketEnd.timeIntervalSince1970)
        bindText(statement, index: 4, value: summary.appName)
        bindOptionalText(statement, index: 5, value: summary.bundleID)
        bindText(statement, index: 6, value: summary.summary)
        bindText(statement, index: 7, value: entitiesJSON)
        sqlite3_bind_int(statement, 8, summary.insufficientEvidence ? 1 : 0)
        bindOptionalText(statement, index: 9, value: model)
        sqlite3_bind_int(statement, 10, Int32(usage?.inputTokens ?? 0))
        sqlite3_bind_int(statement, 11, Int32(usage?.outputTokens ?? 0))
        sqlite3_bind_int(statement, 12, Int32(usage?.audioTokens ?? 0))
        sqlite3_bind_double(statement, 13, Date().timeIntervalSince1970)
        try step(statement)

        if let usage {
            try appendUsageEvent(usage)
        }
    }

    func saveHourSummary(_ summary: HourSummary, usage: LLMUsageEvent?, model: String?) throws {
        let sql = """
            INSERT OR REPLACE INTO hour_summaries(
                id, hour_start, hour_end, summary, llm_model,
                llm_input_tokens, llm_output_tokens, llm_audio_tokens, finalized_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: summary.id)
        sqlite3_bind_double(statement, 2, summary.hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, summary.hourEnd.timeIntervalSince1970)
        bindText(statement, index: 4, value: summary.summary)
        bindOptionalText(statement, index: 5, value: model)
        sqlite3_bind_int(statement, 6, Int32(usage?.inputTokens ?? 0))
        sqlite3_bind_int(statement, 7, Int32(usage?.outputTokens ?? 0))
        sqlite3_bind_int(statement, 8, Int32(usage?.audioTokens ?? 0))
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        try step(statement)

        if let usage {
            try appendUsageEvent(usage)
        }
    }

    func saveTaskSegments(_ segments: [TaskSegmentRecord]) throws {
        guard !segments.isEmpty else { return }

        let sql = """
            INSERT OR REPLACE INTO task_segments(
                id, scope, start_time, end_time, occurred_at, app_name, bundle_id,
                project, workspace, repo, document, url, task, issue_or_goal,
                actions_json, outcome, next_step, status, confidence, evidence_refs_json,
                entities_json, summary, source_summary_id, prompt_version, created_at, updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                COALESCE((SELECT created_at FROM task_segments WHERE id = ?), ?), ?
            );
        """

        for segment in segments {
            let actionsJSON = jsonString(from: segment.actions)
            let evidenceRefsJSON = jsonString(from: segment.evidenceRefs)
            let entitiesJSON = jsonString(from: segment.entities)

            let now = Date().timeIntervalSince1970
            var statement: OpaquePointer?
            try prepare(sql, statement: &statement)
            defer { sqlite3_finalize(statement) }

            bindText(statement, index: 1, value: segment.id)
            bindText(statement, index: 2, value: segment.scope)
            sqlite3_bind_double(statement, 3, segment.startTime.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, segment.endTime.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, segment.occurredAt.timeIntervalSince1970)
            bindOptionalText(statement, index: 6, value: segment.appName)
            bindOptionalText(statement, index: 7, value: segment.bundleID)
            bindOptionalText(statement, index: 8, value: segment.project)
            bindOptionalText(statement, index: 9, value: segment.workspace)
            bindOptionalText(statement, index: 10, value: segment.repo)
            bindOptionalText(statement, index: 11, value: segment.document)
            bindOptionalText(statement, index: 12, value: segment.url)
            bindText(statement, index: 13, value: segment.task)
            bindOptionalText(statement, index: 14, value: segment.issueOrGoal)
            bindText(statement, index: 15, value: actionsJSON)
            bindOptionalText(statement, index: 16, value: segment.outcome)
            bindOptionalText(statement, index: 17, value: segment.nextStep)
            bindText(statement, index: 18, value: segment.status.rawValue)
            sqlite3_bind_double(statement, 19, max(0, min(1, segment.confidence)))
            bindText(statement, index: 20, value: evidenceRefsJSON)
            bindText(statement, index: 21, value: entitiesJSON)
            bindText(statement, index: 22, value: segment.summary)
            bindOptionalText(statement, index: 23, value: segment.sourceSummaryID)
            bindText(statement, index: 24, value: segment.promptVersion)
            bindText(statement, index: 25, value: segment.id)
            sqlite3_bind_double(statement, 26, now)
            sqlite3_bind_double(statement, 27, now)

            try step(statement)
        }
    }

    func listTaskSegments(start: Date, end: Date, limit: Int) throws -> [TaskSegmentRecord] {
        let sql = """
            SELECT id, scope, start_time, end_time, occurred_at, app_name, bundle_id,
                   project, workspace, repo, document, url, task, issue_or_goal, actions_json,
                   outcome, next_step, status, confidence, evidence_refs_json, entities_json,
                   summary, source_summary_id, prompt_version
              FROM task_segments
             WHERE occurred_at >= ? AND occurred_at < ?
             ORDER BY occurred_at DESC, confidence DESC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(max(1, limit)))
        return try decodeTaskSegments(from: statement)
    }

    func queryTaskSegments(
        text: String,
        start: Date?,
        end: Date?,
        limit: Int
    ) throws -> [TaskSegmentRecord] {
        var sql = """
            SELECT id, scope, start_time, end_time, occurred_at, app_name, bundle_id,
                   project, workspace, repo, document, url, task, issue_or_goal, actions_json,
                   outcome, next_step, status, confidence, evidence_refs_json, entities_json,
                   summary, source_summary_id, prompt_version
              FROM task_segments
             WHERE (
                   ? = ''
                   OR task LIKE ?
                   OR issue_or_goal LIKE ?
                   OR outcome LIKE ?
                   OR next_step LIKE ?
                   OR summary LIKE ?
                   OR app_name LIKE ?
                   OR project LIKE ?
                   OR workspace LIKE ?
                   OR repo LIKE ?
                   OR document LIKE ?
                   OR url LIKE ?
                   OR entities_json LIKE ?
             )
        """

        if start != nil && end != nil {
            sql += " AND occurred_at >= ? AND occurred_at < ?"
        }
        sql += " ORDER BY occurred_at DESC, confidence DESC LIMIT ?;"

        let like = "%\(text)%"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: text)
        bindText(statement, index: 2, value: like)
        bindText(statement, index: 3, value: like)
        bindText(statement, index: 4, value: like)
        bindText(statement, index: 5, value: like)
        bindText(statement, index: 6, value: like)
        bindText(statement, index: 7, value: like)
        bindText(statement, index: 8, value: like)
        bindText(statement, index: 9, value: like)
        bindText(statement, index: 10, value: like)
        bindText(statement, index: 11, value: like)
        bindText(statement, index: 12, value: like)
        bindText(statement, index: 13, value: like)

        var nextIndex: Int32 = 14
        if let start, let end {
            sqlite3_bind_double(statement, nextIndex, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, nextIndex + 1, end.timeIntervalSince1970)
            nextIndex += 2
        }
        sqlite3_bind_int(statement, nextIndex, Int32(max(1, limit)))

        return try decodeTaskSegments(from: statement)
    }

    func listIntervalSummaries(hourStart: Date, hourEnd: Date) throws -> [IntervalSummary] {
        let sql = """
            SELECT id, bucket_start, bucket_end, app_name, bundle_id,
                   summary, entities_json, insufficient_evidence
              FROM interval_summaries
             WHERE bucket_start >= ? AND bucket_end <= ?
             ORDER BY bucket_start ASC, app_name ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, hourEnd.timeIntervalSince1970)

        var rows: [IntervalSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entitiesJSON = string(statement, column: 6) ?? "[]"
            let entities: [String]
            if let data = entitiesJSON.data(using: .utf8),
               let decoded = try? jsonDecoder.decode([String].self, from: data) {
                entities = decoded
            } else {
                entities = []
            }

            rows.append(
                IntervalSummary(
                    id: string(statement, column: 0) ?? UUID().uuidString,
                    bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    bucketEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    appName: string(statement, column: 3) ?? "Unknown",
                    bundleID: string(statement, column: 4),
                    summary: string(statement, column: 5) ?? "",
                    entities: entities,
                    insufficientEvidence: sqlite3_column_int(statement, 7) != 0
                )
            )
        }

        return rows
    }

    func markIntervalBucketFinalized(_ bucketStart: Date) throws {
        let sql = "INSERT OR REPLACE INTO finalized_interval_buckets(bucket_start, finalized_at) VALUES (?, ?);"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, bucketStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try step(statement)

        let clearSQL = "DELETE FROM pending_interval_buckets WHERE bucket_start = ?;"
        var clearStatement: OpaquePointer?
        try prepare(clearSQL, statement: &clearStatement)
        defer { sqlite3_finalize(clearStatement) }
        sqlite3_bind_double(clearStatement, 1, bucketStart.timeIntervalSince1970)
        try step(clearStatement)
    }

    func isIntervalBucketFinalized(_ bucketStart: Date) throws -> Bool {
        let sql = "SELECT 1 FROM finalized_interval_buckets WHERE bucket_start = ? LIMIT 1;"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, bucketStart.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func markHourFinalized(_ hourStart: Date) throws {
        let sql = "INSERT OR REPLACE INTO finalized_hours(hour_start, finalized_at) VALUES (?, ?);"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try step(statement)

        let clearSQL = "DELETE FROM pending_hours WHERE hour_start = ?;"
        var clearStatement: OpaquePointer?
        try prepare(clearSQL, statement: &clearStatement)
        defer { sqlite3_finalize(clearStatement) }
        sqlite3_bind_double(clearStatement, 1, hourStart.timeIntervalSince1970)
        try step(clearStatement)
    }

    func isHourFinalized(_ hourStart: Date) throws -> Bool {
        let sql = "SELECT 1 FROM finalized_hours WHERE hour_start = ? LIMIT 1;"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, hourStart.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func enqueuePendingIntervalBucket(_ bucketStart: Date) throws {
        let sql = """
            INSERT INTO pending_interval_buckets(
                bucket_start, next_attempt_at, attempts, last_error, created_at, updated_at
            ) VALUES (?, ?, 0, NULL, ?, ?)
            ON CONFLICT(bucket_start) DO UPDATE SET
                next_attempt_at = CASE
                    WHEN pending_interval_buckets.next_attempt_at > excluded.next_attempt_at THEN excluded.next_attempt_at
                    ELSE pending_interval_buckets.next_attempt_at
                END,
                updated_at = excluded.updated_at;
        """

        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, bucketStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        try step(statement)
    }

    func enqueuePendingHour(_ hourStart: Date) throws {
        let sql = """
            INSERT INTO pending_hours(
                hour_start, next_attempt_at, attempts, last_error, created_at, updated_at
            ) VALUES (?, ?, 0, NULL, ?, ?)
            ON CONFLICT(hour_start) DO UPDATE SET
                next_attempt_at = CASE
                    WHEN pending_hours.next_attempt_at > excluded.next_attempt_at THEN excluded.next_attempt_at
                    ELSE pending_hours.next_attempt_at
                END,
                updated_at = excluded.updated_at;
        """

        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        try step(statement)
    }

    func listDuePendingIntervalBuckets(
        before cutoff: Date,
        now: Date,
        limit: Int
    ) throws -> [PendingIntervalBucketItem] {
        let sql = """
            SELECT bucket_start, attempts
              FROM pending_interval_buckets
             WHERE bucket_start < ? AND next_attempt_at <= ?
             ORDER BY next_attempt_at ASC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(max(1, limit)))

        var output: [PendingIntervalBucketItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(
                PendingIntervalBucketItem(
                    bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    attempts: Int(sqlite3_column_int(statement, 1))
                )
            )
        }
        return output
    }

    func listDuePendingHours(
        before cutoff: Date,
        now: Date,
        limit: Int
    ) throws -> [PendingHourItem] {
        let sql = """
            SELECT hour_start, attempts
              FROM pending_hours
             WHERE hour_start < ? AND next_attempt_at <= ?
             ORDER BY next_attempt_at ASC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(max(1, limit)))

        var output: [PendingHourItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(
                PendingHourItem(
                    hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    attempts: Int(sqlite3_column_int(statement, 1))
                )
            )
        }
        return output
    }

    func markPendingIntervalBucketFailed(
        _ bucketStart: Date,
        errorMessage: String,
        nextAttemptAt: Date
    ) throws {
        let sql = """
            UPDATE pending_interval_buckets
               SET attempts = attempts + 1,
                   last_error = ?,
                   next_attempt_at = ?,
                   updated_at = ?
             WHERE bucket_start = ?;
        """

        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: errorMessage)
        sqlite3_bind_double(statement, 2, nextAttemptAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, bucketStart.timeIntervalSince1970)
        try step(statement)
    }

    func markPendingHourFailed(
        _ hourStart: Date,
        errorMessage: String,
        nextAttemptAt: Date
    ) throws {
        let sql = """
            UPDATE pending_hours
               SET attempts = attempts + 1,
                   last_error = ?,
                   next_attempt_at = ?,
                   updated_at = ?
             WHERE hour_start = ?;
        """

        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: errorMessage)
        sqlite3_bind_double(statement, 2, nextAttemptAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, hourStart.timeIntervalSince1970)
        try step(statement)
    }

    func appendUsageEvent(_ event: LLMUsageEvent) throws {
        let sql = """
            INSERT INTO llm_usage_events(
                id, kind, created_at, model, input_tokens, output_tokens, audio_tokens, estimated_cost_usd
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: event.id)
        bindText(statement, index: 2, value: event.kind)
        sqlite3_bind_double(statement, 3, event.createdAt.timeIntervalSince1970)
        bindText(statement, index: 4, value: event.model)
        sqlite3_bind_int(statement, 5, Int32(event.inputTokens))
        sqlite3_bind_int(statement, 6, Int32(event.outputTokens))
        sqlite3_bind_int(statement, 7, Int32(event.audioTokens))
        sqlite3_bind_double(statement, 8, event.estimatedCostUSD)
        try step(statement)
    }

    func usageTotals(day: Date?, calendar: Calendar) throws -> LLMUsageTotals {
        var sql = "SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), COALESCE(SUM(audio_tokens), 0), COALESCE(SUM(estimated_cost_usd), 0) FROM llm_usage_events"
        var start: Double?
        var end: Double?
        if let day {
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            start = dayStart.timeIntervalSince1970
            end = dayEnd.timeIntervalSince1970
            sql += " WHERE created_at >= ? AND created_at < ?"
        }
        sql += ";"

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        if let start, let end {
            sqlite3_bind_double(statement, 1, start)
            sqlite3_bind_double(statement, 2, end)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return LLMUsageTotals()
        }

        return LLMUsageTotals(
            requestCount: Int(sqlite3_column_int(statement, 0)),
            inputTokens: Int(sqlite3_column_int(statement, 1)),
            outputTokens: Int(sqlite3_column_int(statement, 2)),
            audioTokens: Int(sqlite3_column_int(statement, 3)),
            estimatedCostUSD: sqlite3_column_double(statement, 4)
        )
    }

    func listHourSummaries(day: Date, calendar: Calendar) throws -> [HourSummary] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)

        let sql = """
            SELECT id, hour_start, hour_end, summary
              FROM hour_summaries
             WHERE hour_start >= ? AND hour_start < ?
             ORDER BY hour_start ASC;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, dayEnd.timeIntervalSince1970)

        var rows: [HourSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                HourSummary(
                    id: string(statement, column: 0) ?? UUID().uuidString,
                    hourStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    hourEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    summary: string(statement, column: 3) ?? ""
                )
            )
        }
        return rows
    }

    func saveMemoryPayload(_ payload: MemoryPayload, status: String, responseJSON: String?) throws {
        let entitiesJSON = String(data: (try? jsonEncoder.encode(payload.entities)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let payloadJSON = String(data: (try? jsonEncoder.encode(payload)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"

        let sql = """
            INSERT OR REPLACE INTO mem0_memory(
                id, occurred_at, scope, app_name, project, summary,
                entities_json, payload_json, mem0_status, mem0_response_json,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM mem0_memory WHERE id = ?), ?), ?);
        """

        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: payload.id)
        sqlite3_bind_double(statement, 2, payload.occurredAt.timeIntervalSince1970)
        bindText(statement, index: 3, value: payload.scope)
        bindOptionalText(statement, index: 4, value: payload.appName)
        bindOptionalText(statement, index: 5, value: payload.project)
        bindText(statement, index: 6, value: payload.summary)
        bindText(statement, index: 7, value: entitiesJSON)
        bindText(statement, index: 8, value: payloadJSON)
        bindText(statement, index: 9, value: status)
        bindOptionalText(statement, index: 10, value: responseJSON)
        bindText(statement, index: 11, value: payload.id)
        sqlite3_bind_double(statement, 12, now)
        sqlite3_bind_double(statement, 13, now)

        try step(statement)
    }

    func listMem0BackfillCandidates(
        retryBefore: Date,
        limit: Int
    ) throws -> [PendingMem0Item] {
        let sql = """
            SELECT payload_json, mem0_status
              FROM mem0_memory
             WHERE mem0_status NOT IN ('ok', 'disabled')
               AND updated_at <= ?
             ORDER BY occurred_at ASC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, retryBefore.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var output: [PendingMem0Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let payloadJSON = string(statement, column: 0),
                  let data = payloadJSON.data(using: .utf8),
                  let payload = try? jsonDecoder.decode(MemoryPayload.self, from: data)
            else {
                continue
            }

            output.append(
                PendingMem0Item(
                    payload: payload,
                    status: string(statement, column: 1) ?? "pending"
                )
            )
        }

        return output
    }

    func queryMemories(text: String, day: Date?, calendar: Calendar) throws -> [MemoryRecord] {
        var sql = """
            SELECT occurred_at, scope, app_name, project, summary, entities_json
              FROM mem0_memory
             WHERE (summary LIKE ? OR app_name LIKE ? OR project LIKE ?)
        """
        let like = "%\(text)%"

        var start: Date?
        var end: Date?
        if let day {
            start = calendar.startOfDay(for: day)
            end = calendar.date(byAdding: .day, value: 1, to: start!)
            sql += " AND occurred_at >= ? AND occurred_at < ?"
        }
        sql += " ORDER BY occurred_at DESC LIMIT 80;"

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: like)
        bindText(statement, index: 2, value: like)
        bindText(statement, index: 3, value: like)
        if let start, let end {
            sqlite3_bind_double(statement, 4, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, end.timeIntervalSince1970)
        }

        var rows: [MemoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entitiesJSON = string(statement, column: 5) ?? "[]"
            let entities: [String]
            if let data = entitiesJSON.data(using: .utf8),
               let decoded = try? jsonDecoder.decode([String].self, from: data) {
                entities = decoded
            } else {
                entities = []
            }

            rows.append(
                MemoryRecord(
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    scope: string(statement, column: 1) ?? "",
                    appName: string(statement, column: 2),
                    project: string(statement, column: 3),
                    summary: string(statement, column: 4) ?? "",
                    entities: entities
                )
            )
        }

        return rows
    }

    func listMem0MemoryRecords(start: Date?, end: Date?, limit: Int) throws -> [MemoryRecord] {
        var sql = """
            SELECT occurred_at, scope, app_name, project, summary, entities_json
              FROM mem0_memory
             WHERE 1 = 1
        """
        var bindIndex: Int32 = 1
        if start != nil {
            sql += " AND occurred_at >= ?"
        }
        if end != nil {
            sql += " AND occurred_at < ?"
        }
        sql += " ORDER BY occurred_at DESC LIMIT ?;"

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        if let start {
            sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970)
            bindIndex += 1
        }
        if let end {
            sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(max(1, min(limit, 5_000))))

        var rows: [MemoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entitiesJSON = string(statement, column: 5) ?? "[]"
            let entities: [String]
            if let data = entitiesJSON.data(using: .utf8),
               let decoded = try? jsonDecoder.decode([String].self, from: data) {
                entities = decoded
            } else {
                entities = []
            }

            rows.append(
                MemoryRecord(
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    scope: string(statement, column: 1) ?? "",
                    appName: string(statement, column: 2),
                    project: string(statement, column: 3),
                    summary: string(statement, column: 4) ?? "",
                    entities: entities
                )
            )
        }

        return rows
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorPointer)
            throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
        }
    }

    private func step(_ statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
        }
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            bindText(statement, index: index, value: value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func jsonString(from value: [String]) -> String {
        String(
            data: (try? jsonEncoder.encode(value)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"
    }

    private func decodeStringArray(_ json: String?) -> [String] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let decoded = try? jsonDecoder.decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func decodeTaskSegments(from statement: OpaquePointer?) throws -> [TaskSegmentRecord] {
        var rows: [TaskSegmentRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let statusRaw = string(statement, column: 17) ?? TaskSegmentStatus.unknown.rawValue
            let status = TaskSegmentStatus(rawValue: statusRaw) ?? .unknown
            let confidence = max(0, min(1, sqlite3_column_double(statement, 18)))
            let actions = decodeStringArray(string(statement, column: 14))
            let evidenceRefs = decodeStringArray(string(statement, column: 19))
            let entities = decodeStringArray(string(statement, column: 20))

            rows.append(
                TaskSegmentRecord(
                    id: string(statement, column: 0) ?? UUID().uuidString,
                    scope: string(statement, column: 1) ?? "interval",
                    startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    appName: string(statement, column: 5),
                    bundleID: string(statement, column: 6),
                    project: string(statement, column: 7),
                    workspace: string(statement, column: 8),
                    repo: string(statement, column: 9),
                    document: string(statement, column: 10),
                    url: string(statement, column: 11),
                    task: string(statement, column: 12) ?? "unknown task",
                    issueOrGoal: string(statement, column: 13),
                    actions: actions,
                    outcome: string(statement, column: 15),
                    nextStep: string(statement, column: 16),
                    status: status,
                    confidence: confidence,
                    evidenceRefs: evidenceRefs,
                    entities: entities,
                    summary: string(statement, column: 21) ?? "",
                    sourceSummaryID: string(statement, column: 22),
                    promptVersion: string(statement, column: 23) ?? "v1"
                )
            )
        }
        return rows
    }

    private func parseAnalysisJSON(_ analysisJSON: String?) -> ArtifactAnalysis? {
        guard let analysisJSON, let data = analysisJSON.data(using: .utf8) else {
            return nil
        }
        return try? jsonDecoder.decode(ArtifactAnalysis.self, from: data)
    }

    private func listEvidencePurgeCandidates(
        kind: ArtifactKind,
        capturedBefore cutoff: Date,
        limit: Int
    ) throws -> [EvidencePurgeCandidate] {
        let sql = """
            SELECT id, artifact_path
              FROM evidence
             WHERE kind = ? AND captured_at < ?
             ORDER BY captured_at ASC
             LIMIT ?;
        """

        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: kind.rawValue)
        sqlite3_bind_double(statement, 2, cutoff.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(max(1, limit)))

        var output: [EvidencePurgeCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, column: 0),
                  let path = string(statement, column: 1)
            else {
                continue
            }
            output.append(EvidencePurgeCandidate(id: id, path: path))
        }

        return output
    }

    private func lastErrorMessage() -> String {
        guard let db else { return "SQLite database unavailable" }
        guard let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

private struct EvidencePurgeCandidate: Sendable {
    let id: String
    let path: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
