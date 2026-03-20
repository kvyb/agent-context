import Foundation
import SQLite3

struct SQLiteStoreRowDecoder: Sendable {
    func decodeArtifactMetadata(
        from statement: OpaquePointer?,
        string: (OpaquePointer?, Int32) -> String?,
        fallbackID: String? = nil,
        fallbackAppName: String = "Unknown"
    ) -> ArtifactMetadata {
        ArtifactMetadata(
            id: string(statement, 0) ?? fallbackID ?? UUID().uuidString,
            kind: ArtifactKind(rawValue: string(statement, 1) ?? "screenshot") ?? .screenshot,
            path: string(statement, 2) ?? "",
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            app: AppDescriptor(
                appName: string(statement, 4) ?? fallbackAppName,
                bundleID: string(statement, 5),
                pid: sqlite3_column_int(statement, 6)
            ),
            window: WindowContext(
                title: string(statement, 7),
                documentPath: string(statement, 8),
                url: string(statement, 9),
                workspace: string(statement, 10),
                project: string(statement, 11)
            ),
            intervalID: string(statement, 12),
            captureReason: string(statement, 13) ?? "unknown",
            sequenceInInterval: Int(sqlite3_column_int(statement, 14))
        )
    }

    func jsonString(from value: [String], encoder: JSONEncoder) -> String {
        String(
            data: (try? encoder.encode(value)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"
    }

    func decodeStringArray(_ json: String?, decoder: JSONDecoder) -> [String] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let decoded = try? decoder.decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func decodeTaskSegments(
        from statement: OpaquePointer?,
        string: (OpaquePointer?, Int32) -> String?,
        decoder: JSONDecoder
    ) -> [TaskSegmentRecord] {
        var rows: [TaskSegmentRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let statusRaw = string(statement, 19) ?? TaskSegmentStatus.unknown.rawValue
            let status = TaskSegmentStatus(rawValue: statusRaw) ?? .unknown
            let confidence = max(0, min(1, sqlite3_column_double(statement, 20)))
            let actions = decodeStringArray(string(statement, 14), decoder: decoder)
            let people = decodeStringArray(string(statement, 17), decoder: decoder)
            let evidenceRefs = decodeStringArray(string(statement, 21), decoder: decoder)
            let evidenceExcerpts = decodeStringArray(string(statement, 22), decoder: decoder)
            let entities = decodeStringArray(string(statement, 23), decoder: decoder)
            let artifactKinds = decodeStringArray(string(statement, 24), decoder: decoder).compactMap(ArtifactKind.init(rawValue:))
            let sourceKinds = decodeStringArray(string(statement, 25), decoder: decoder).compactMap(PromotedSourceKind.init(rawValue:))

            rows.append(
                TaskSegmentRecord(
                    id: string(statement, 0) ?? UUID().uuidString,
                    scope: string(statement, 1) ?? "interval",
                    startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    appName: string(statement, 5),
                    bundleID: string(statement, 6),
                    project: string(statement, 7),
                    workspace: string(statement, 8),
                    repo: string(statement, 9),
                    document: string(statement, 10),
                    url: string(statement, 11),
                    task: string(statement, 12) ?? "unknown task",
                    issueOrGoal: string(statement, 13),
                    actions: actions,
                    outcome: string(statement, 15),
                    nextStep: string(statement, 16),
                    people: people,
                    blocker: string(statement, 18),
                    status: status,
                    confidence: confidence,
                    evidenceRefs: evidenceRefs,
                    evidenceExcerpts: evidenceExcerpts,
                    entities: entities,
                    artifactKinds: artifactKinds,
                    sourceKinds: sourceKinds,
                    summary: string(statement, 26) ?? "",
                    sourceSummaryID: string(statement, 27),
                    promptVersion: string(statement, 28) ?? "v1"
                )
            )
        }
        return rows
    }

    func decodeTranscriptUnits(
        from statement: OpaquePointer?,
        string: (OpaquePointer?, Int32) -> String?,
        decoder: JSONDecoder
    ) -> [TranscriptUnitRecord] {
        var rows: [TranscriptUnitRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                TranscriptUnitRecord(
                    id: string(statement, 0) ?? UUID().uuidString,
                    evidenceID: string(statement, 1) ?? "",
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    appName: string(statement, 3),
                    bundleID: string(statement, 4),
                    project: string(statement, 5),
                    workspace: string(statement, 6),
                    task: string(statement, 7),
                    sessionID: string(statement, 8),
                    kind: TranscriptUnitKind(rawValue: string(statement, 9) ?? TranscriptUnitKind.transcriptExcerpt.rawValue) ?? .transcriptExcerpt,
                    speakerLabel: string(statement, 10),
                    summary: string(statement, 11) ?? "",
                    excerptText: string(statement, 12) ?? "",
                    topicTags: decodeStringArray(string(statement, 13), decoder: decoder),
                    people: decodeStringArray(string(statement, 14), decoder: decoder),
                    entities: decodeStringArray(string(statement, 15), decoder: decoder),
                    sourceEvidenceRefs: decodeStringArray(string(statement, 16), decoder: decoder),
                    sourceExcerpts: decodeStringArray(string(statement, 17), decoder: decoder)
                )
            )
        }
        return rows
    }

    func decodeStoredEvidenceRecord(
        from statement: OpaquePointer?,
        fallbackAppName: String?,
        string: (OpaquePointer?, Int32) -> String?,
        decoder: JSONDecoder
    ) -> StoredEvidenceRecord {
        let analysis = parseAnalysisJSON(string(statement, 15), decoder: decoder)
        let metadata = decodeArtifactMetadata(
            from: statement,
            string: string,
            fallbackAppName: fallbackAppName ?? "Unknown"
        )
        return StoredEvidenceRecord(metadata: metadata, analysis: analysis)
    }

    func parseAnalysisJSON(_ analysisJSON: String?, decoder: JSONDecoder) -> ArtifactAnalysis? {
        guard let analysisJSON, let data = analysisJSON.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(ArtifactAnalysis.self, from: data)
    }

    func evidenceDetailItem(
        id: String,
        timestamp: Date,
        kind: ArtifactKind,
        appName: String,
        analysis: ArtifactAnalysis?
    ) -> EvidenceDetailItem {
        EvidenceDetailItem(
            id: id,
            timestamp: timestamp,
            kind: kind,
            appName: appName,
            description: analysis?.description ?? (analysis?.summary ?? "Pending analysis"),
            contentDescription: analysis?.contentDescription ?? (analysis?.description ?? analysis?.summary ?? "Pending analysis"),
            layoutDescription: analysis?.layoutDescription ?? (analysis?.contentDescription ?? analysis?.description ?? analysis?.summary ?? "Pending analysis"),
            problem: analysis?.problem,
            success: analysis?.success,
            userContribution: analysis?.userContribution,
            suggestionOrDecision: analysis?.suggestionOrDecision,
            status: analysis?.status ?? .none,
            confidence: analysis?.confidence ?? 0,
            summary: analysis?.summary ?? "Pending analysis",
            transcript: analysis?.transcript,
            salientText: analysis?.salientText ?? [],
            uiElements: analysis?.uiElements ?? [],
            entities: analysis?.entities ?? [],
            project: analysis?.project,
            workspace: analysis?.workspace,
            task: analysis?.task,
            evidence: analysis?.evidence ?? []
        )
    }
}
