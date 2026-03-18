import Foundation

final class SQLiteBM25MemoryRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let database: SQLiteStore
    private let ranker: BM25Ranker
    private let scopeParser: MemoryQueryScopeParser
    private let transcriptIndicators = ["transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"]
    private let interviewMarkers = ["interview", "candidate", "metaview", "notetaker", "zoom"]

    init(
        database: SQLiteStore,
        ranker: BM25Ranker,
        scopeParser: MemoryQueryScopeParser
    ) {
        self.database = database
        self.ranker = ranker
        self.scopeParser = scopeParser
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        let queryTerms = scopeParser.queryTerms(for: queries.joined(separator: " "))
        guard !queryTerms.isEmpty else {
            return []
        }
        let transcriptLike = isTranscriptLikeQuery(queries)
        let lookupText = bestTaskSegmentLookupText(queries: queries, queryTerms: queryTerms)
        let taskSegments = await loadTaskSegments(
            lookupText: lookupText,
            scope: scope,
            limit: max(limit * 3, 24)
        )

        let scopedRows: [MemoryRecord]
        do {
            scopedRows = try await database.listMem0MemoryRecords(
                start: scope.start,
                end: scope.end,
                limit: 500
            )
        } catch {
            return []
        }

        let rows: [MemoryRecord]
        if scopedRows.isEmpty, (scope.start != nil || scope.end != nil) {
            rows = (try? await database.listMem0MemoryRecords(start: nil, end: nil, limit: 400)) ?? []
        } else {
            rows = scopedRows
        }
        let taskSegmentOutput = rankedTaskSegmentHits(
            taskSegments,
            queryTerms: queryTerms,
            limit: limit
        )
        let transcriptOutput = transcriptLike ? await transcriptEvidenceHits(
            queries: queries,
            queryTerms: queryTerms,
            scope: scope,
            anchorSegments: taskSegments,
            limit: max(limit * 2, 10)
        ) : []

        guard !rows.isEmpty else {
            return combineLexicalHits(taskSegmentOutput + transcriptOutput, limit: limit)
        }

        let docs = rows.map { row in
            let entities = row.entities.joined(separator: " ")
            let project = row.project?.nilIfEmpty ?? ""
            let app = row.appName?.nilIfEmpty ?? ""
            return "\(row.summary) \(project) \(app) \(entities) \(row.scope)"
        }.map(scopeParser.tokenize)

        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var output: [MemoryEvidenceHit] = []
        var seen = Set<String>()

        for (index, row) in rows.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 else { continue }

            let lexicalScore = min(1, rawScore / maxScore)
            let ageHours = Date().timeIntervalSince(row.occurredAt) / 3600
            let recencyBoost = ageHours < 24 ? 0.04 : (ageHours < 24 * 7 ? 0.02 : 0)

            let key = "bm25|\(Int(row.occurredAt.timeIntervalSince1970 / 30))|\(row.summary.prefix(120).lowercased())"
            guard seen.insert(key).inserted else { continue }

            output.append(
                MemoryEvidenceHit(
                    id: key,
                    source: .bm25Store,
                    text: row.summary,
                    appName: row.appName?.nilIfEmpty,
                    project: row.project?.nilIfEmpty,
                    occurredAt: row.occurredAt,
                    metadata: [
                        "scope": row.scope,
                        "entities": row.entities.joined(separator: "|")
                    ],
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: lexicalScore + recencyBoost
                )
            )
        }

        return combineLexicalHits(output + taskSegmentOutput + transcriptOutput, limit: limit)
    }

    private func loadTaskSegments(
        lookupText: String,
        scope: MemoryQueryScope,
        limit: Int
    ) async -> [TaskSegmentRecord] {
        let segments: [TaskSegmentRecord]
        do {
            segments = try await database.queryTaskSegments(
                text: lookupText,
                start: scope.start,
                end: scope.end,
                limit: max(limit, 1)
            )
        } catch {
            return []
        }
        return segments
    }

    private func rankedTaskSegmentHits(
        _ segments: [TaskSegmentRecord],
        queryTerms: [String],
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard !segments.isEmpty else {
            return []
        }

        let docs = segments.map { segment in
            taskSegmentDocument(segment)
        }.map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var output: [MemoryEvidenceHit] = []
        var seen = Set<String>()

        for (index, segment) in segments.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 else { continue }

            let lexicalScore = min(1, rawScore / maxScore)
            let ageHours = Date().timeIntervalSince(segment.occurredAt) / 3600
            let recencyBoost = ageHours < 24 ? 0.05 : (ageHours < 24 * 7 ? 0.03 : 0)
            let confidenceBoost = min(0.08, max(0, segment.confidence * 0.08))
            let key = "task-segment|\(segment.id)"
            guard seen.insert(key).inserted else { continue }

            output.append(
                MemoryEvidenceHit(
                    id: key,
                    source: .bm25Store,
                    text: taskSegmentSummary(segment),
                    appName: segment.appName?.nilIfEmpty,
                    project: segment.project?.nilIfEmpty,
                    occurredAt: segment.occurredAt,
                    metadata: [
                        "scope": segment.scope,
                        "workspace": segment.workspace ?? "",
                        "repo": segment.repo ?? "",
                        "document": segment.document ?? "",
                        "url": segment.url ?? "",
                        "entities": segment.entities.joined(separator: "|"),
                        "task_segment_status": segment.status.rawValue
                    ],
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: lexicalScore + recencyBoost + confidenceBoost
                )
            )
        }

        return output
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func transcriptEvidenceHits(
        queries: [String],
        queryTerms: [String],
        scope: MemoryQueryScope,
        anchorSegments: [TaskSegmentRecord],
        limit: Int
    ) async -> [MemoryEvidenceHit] {
        let windows = evidenceWindows(scope: scope, anchorSegments: anchorSegments)
        guard !windows.isEmpty else {
            return []
        }

        var evidenceRows: [StoredEvidenceRecord] = []
        var seenEvidenceIDs = Set<String>()
        for window in windows {
            let rows: [StoredEvidenceRecord]
            do {
                rows = try await database.listEvidenceRecords(
                    start: window.start,
                    end: window.end,
                    limit: max(limit * 8, 64)
                )
            } catch {
                continue
            }

            for row in rows {
                guard seenEvidenceIDs.insert(row.metadata.id).inserted else { continue }
                guard shouldIncludeEvidence(row, queries: queries) else { continue }
                evidenceRows.append(row)
            }
        }

        guard !evidenceRows.isEmpty else {
            return []
        }

        let docs = evidenceRows.map(evidenceDocument).map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)
        var hits: [MemoryEvidenceHit] = []

        for (index, row) in evidenceRows.enumerated() {
            let rawScore = scores[index]
            let lexicalScore = rawScore > 0 ? min(1, rawScore / maxScore) : 0
            let transcriptBoost = row.metadata.kind == .audio && hasTranscript(row) ? 0.72 : 0.42
            let markerBoost = containsInterviewMarker(evidenceDocument(row)) ? 0.12 : 0
            let appBoost = row.metadata.app.appName.lowercased().contains("zoom") ? 0.06 : 0
            let scoreFloor = hasTranscript(row) ? transcriptBoost : 0.22
            let hybridScore = min(1.35, max(lexicalScore, scoreFloor) + markerBoost + appBoost)

            hits.append(
                MemoryEvidenceHit(
                    id: "evidence|\(row.metadata.id)",
                    source: .bm25Store,
                    text: evidenceSummary(row),
                    appName: row.metadata.app.appName.nilIfEmpty,
                    project: row.analysis?.project?.nilIfEmpty ?? row.metadata.window.project?.nilIfEmpty,
                    occurredAt: row.metadata.capturedAt,
                    metadata: [
                        "scope": "evidence",
                        "artifact_kind": row.metadata.kind.rawValue,
                        "capture_reason": row.metadata.captureReason,
                        "window_title": row.metadata.window.title ?? "",
                        "workspace": row.analysis?.workspace ?? row.metadata.window.workspace ?? "",
                        "task": row.analysis?.task ?? "",
                        "has_transcript": hasTranscript(row) ? "true" : "false"
                    ],
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: hybridScore
                )
            )
        }

        return hits
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func bestTaskSegmentLookupText(queries: [String], queryTerms: [String]) -> String {
        let exactQuery = queries.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !exactQuery.isEmpty {
            return exactQuery
        }
        return queryTerms.joined(separator: " ")
    }

    private func taskSegmentDocument(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.joined(separator: " ")
        let entities = segment.entities.joined(separator: " ")
        let fields = [
            segment.task,
            segment.issueOrGoal ?? "",
            actions,
            segment.outcome ?? "",
            segment.nextStep ?? "",
            segment.summary,
            segment.project ?? "",
            segment.appName ?? "",
            segment.workspace ?? "",
            segment.repo ?? "",
            segment.document ?? "",
            segment.url ?? "",
            entities,
            segment.status.rawValue,
            segment.scope
        ]
        return fields.joined(separator: " ")
    }

    private func taskSegmentSummary(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.prefix(3).joined(separator: "; ")
        let actionsPart = actions.isEmpty ? "" : " | Actions: \(actions)"
        let outcomePart = segment.outcome?.nilIfEmpty.map { " | Outcome: \($0)" } ?? ""
        let nextStepPart = segment.nextStep?.nilIfEmpty.map { " | Next step: \($0)" } ?? ""
        let issuePart = segment.issueOrGoal?.nilIfEmpty.map { " | Issue/Goal: \($0)" } ?? ""
        let projectPart = segment.project?.nilIfEmpty.map { " | Project: \($0)" } ?? ""
        return "Task: \(segment.task) | Status: \(segment.status.rawValue)\(issuePart)\(actionsPart)\(outcomePart)\(nextStepPart)\(projectPart)"
    }

    private func evidenceWindows(
        scope: MemoryQueryScope,
        anchorSegments: [TaskSegmentRecord]
    ) -> [(start: Date?, end: Date?)] {
        let sortedAnchors = anchorSegments
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)

        let anchorWindows = sortedAnchors.compactMap { segment in
            let start = calendarDate(byAddingMinutes: -5, to: segment.startTime)
            let end = calendarDate(byAddingMinutes: 5, to: segment.endTime)
            return (start, end)
        }

        if !anchorWindows.isEmpty {
            return anchorWindows
        }

        if let start = scope.start, let end = scope.end {
            return [(start, end)]
        }

        return []
    }

    private func combineLexicalHits(_ hits: [MemoryEvidenceHit], limit: Int) -> [MemoryEvidenceHit] {
        hits
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .reduce(into: [MemoryEvidenceHit]()) { acc, hit in
                if acc.contains(where: { $0.id == hit.id }) {
                    return
                }
                acc.append(hit)
            }
            .prefix(limit)
            .map { $0 }
    }

    private func isTranscriptLikeQuery(_ queries: [String]) -> Bool {
        let lowered = queries.joined(separator: " ").lowercased()
        return transcriptIndicators.contains { lowered.contains($0) }
    }

    private func shouldIncludeEvidence(_ row: StoredEvidenceRecord, queries: [String]) -> Bool {
        let loweredQuery = queries.joined(separator: " ").lowercased()
        if row.metadata.kind == .audio {
            return hasTranscript(row)
        }

        let document = evidenceDocument(row)
        if loweredQuery.contains("transcript") {
            return containsInterviewMarker(document)
        }
        return containsInterviewMarker(document) && row.metadata.app.appName.lowercased().contains("zoom")
    }

    private func evidenceDocument(_ row: StoredEvidenceRecord) -> String {
        let analysis = row.analysis
        let summary = analysis?.summary ?? ""
        let transcript = analysis?.transcript ?? ""
        let description = analysis?.description ?? ""
        let task = analysis?.task ?? ""
        let project = analysis?.project ?? ""
        let workspace = analysis?.workspace ?? ""
        let title = row.metadata.window.title ?? ""
        let windowProject = row.metadata.window.project ?? ""
        let windowWorkspace = row.metadata.window.workspace ?? ""
        let appName = row.metadata.app.appName
        let entities = analysis?.entities.joined(separator: " ") ?? ""
        let evidence = analysis?.evidence.joined(separator: " ") ?? ""
        let fields = [
            summary,
            transcript,
            description,
            task,
            project,
            workspace,
            title,
            windowProject,
            windowWorkspace,
            appName,
            entities,
            evidence
        ]
        return fields.joined(separator: " ")
    }

    private func evidenceSummary(_ row: StoredEvidenceRecord) -> String {
        let summary = row.analysis.map { $0.summary.nilIfEmpty ?? $0.description } ?? "Retrieved evidence"
        let transcript = row.analysis?.transcript?.nilIfEmpty
        if let transcript {
            return "Transcript summary: \(summary) | Transcript: \(transcript)"
        }
        return summary
    }

    private func hasTranscript(_ row: StoredEvidenceRecord) -> Bool {
        row.analysis?.transcript?.nilIfEmpty != nil
    }

    private func containsInterviewMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return interviewMarkers.contains { lowered.contains($0) }
    }

    private func calendarDate(byAddingMinutes minutes: Int, to date: Date) -> Date? {
        Calendar.autoupdatingCurrent.date(byAdding: .minute, value: minutes, to: date)
    }
}
