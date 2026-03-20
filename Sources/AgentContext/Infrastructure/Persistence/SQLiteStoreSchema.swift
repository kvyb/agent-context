import Foundation
import SQLite3

enum SQLiteStoreSchema {
    static func migrate(db: OpaquePointer?) throws {
        for sql in statements {
            var errorPointer: UnsafeMutablePointer<Int8>?
            let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
            if code != SQLITE_OK {
                let message = errorPointer.map { String(cString: $0) } ?? "SQLite migration error"
                sqlite3_free(errorPointer)
                if sql.contains("ALTER TABLE"), message.lowercased().contains("duplicate column name") {
                    continue
                }
                throw NSError(domain: "SQLiteStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private static let statements = [
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
        CREATE TABLE IF NOT EXISTS artifact_perceptions (
            evidence_id TEXT PRIMARY KEY,
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
            analysis_json TEXT NOT NULL,
            llm_model TEXT,
            llm_input_tokens INTEGER DEFAULT 0,
            llm_output_tokens INTEGER DEFAULT 0,
            llm_audio_tokens INTEGER DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_artifact_perceptions_captured_at ON artifact_perceptions(captured_at);",
        "CREATE INDEX IF NOT EXISTS idx_artifact_perceptions_app_project ON artifact_perceptions(app_name, project);",
        """
        INSERT OR IGNORE INTO artifact_perceptions(
            evidence_id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
            window_title, document_path, window_url, workspace, project,
            interval_id, capture_reason, sequence_in_interval, analysis_json,
            llm_model, llm_input_tokens, llm_output_tokens, llm_audio_tokens,
            created_at, updated_at
        )
        SELECT id, kind, artifact_path, captured_at, app_name, bundle_id, pid,
               window_title, document_path, window_url, workspace, project,
               interval_id, capture_reason, sequence_in_interval, analysis_json,
               llm_model, llm_input_tokens, llm_output_tokens, llm_audio_tokens,
               captured_at, captured_at
          FROM evidence
         WHERE analysis_json IS NOT NULL;
        """,
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
            people_json TEXT NOT NULL DEFAULT '[]',
            blocker TEXT,
            status TEXT NOT NULL,
            confidence REAL NOT NULL,
            evidence_refs_json TEXT NOT NULL,
            evidence_excerpts_json TEXT NOT NULL DEFAULT '[]',
            entities_json TEXT NOT NULL,
            artifact_kinds_json TEXT NOT NULL DEFAULT '[]',
            source_kinds_json TEXT NOT NULL DEFAULT '[]',
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
        CREATE TABLE IF NOT EXISTS transcript_units (
            id TEXT PRIMARY KEY,
            evidence_id TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            app_name TEXT,
            bundle_id TEXT,
            project TEXT,
            workspace TEXT,
            task TEXT,
            session_id TEXT,
            unit_kind TEXT NOT NULL,
            speaker_label TEXT,
            summary TEXT NOT NULL,
            excerpt_text TEXT NOT NULL,
            topic_tags_json TEXT NOT NULL,
            people_json TEXT NOT NULL,
            entities_json TEXT NOT NULL,
            source_evidence_refs_json TEXT NOT NULL,
            source_excerpts_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_transcript_units_time ON transcript_units(occurred_at);",
        "CREATE INDEX IF NOT EXISTS idx_transcript_units_session ON transcript_units(session_id);",
        "CREATE INDEX IF NOT EXISTS idx_transcript_units_project ON transcript_units(project);",
        "ALTER TABLE task_segments ADD COLUMN people_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE task_segments ADD COLUMN blocker TEXT;",
        "ALTER TABLE task_segments ADD COLUMN evidence_excerpts_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE task_segments ADD COLUMN artifact_kinds_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE task_segments ADD COLUMN source_kinds_json TEXT NOT NULL DEFAULT '[]';",
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
}
