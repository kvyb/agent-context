import Foundation

final class SQLiteBM25MemoryRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let database: SQLiteStore
    private let ranker: BM25Ranker
    private let scopeParser: MemoryQueryScopeParser
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer
    private let artifactSupport: SQLiteBM25ArtifactSupport
    private let hitReranker: SQLiteBM25HitReranker

    init(
        database: SQLiteStore,
        ranker: BM25Ranker,
        scopeParser: MemoryQueryScopeParser
    ) {
        self.database = database
        self.ranker = ranker
        self.scopeParser = scopeParser
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: scopeParser)
        let artifactSupport = SQLiteBM25ArtifactSupport()
        self.artifactSupport = artifactSupport
        self.hitReranker = SQLiteBM25HitReranker()
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        let combinedQuestion = queries.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerms = scopeParser.queryTerms(for: combinedQuestion)
        guard !queryTerms.isEmpty else {
            return []
        }

        let analysis = questionAnalyzer.analyze(question: combinedQuestion)
        let lookupText = bestTaskSegmentLookupText(queries: queries, queryTerms: queryTerms)
        let candidateLimit = max(limit * 3, 18)

        let taskSegments = await loadTaskSegments(
            lookupText: lookupText,
            scope: scope,
            limit: max(candidateLimit * 2, 24)
        )
        let transcriptUnits = await loadTranscriptUnits(
            lookupText: lookupText,
            scope: scope,
            analysis: analysis,
            anchorSegments: taskSegments,
            limit: max(candidateLimit * 2, 24)
        )
        let artifactPerceptions = await loadArtifactPerceptions(
            scope: scope,
            analysis: analysis,
            anchorSegments: taskSegments,
            limit: max(candidateLimit * 3, 48)
        )
        let memoryRows = await loadMemorySummaryRows(
            scope: scope,
            analysis: analysis,
            limit: max(candidateLimit * 4, 64)
        )

        let taskSegmentHits = rankedTaskSegmentHits(
            taskSegments,
            queryTerms: queryTerms,
            analysis: analysis,
            limit: candidateLimit
        )
        let transcriptUnitHits = transcriptUnitHits(
            transcriptUnits,
            queryTerms: queryTerms,
            analysis: analysis,
            limit: max(candidateLimit, 10)
        )
        let transcriptHits = analysis.prefersLexicalFirst
            ? transcriptEvidenceHits(
                evidenceRows: artifactPerceptions,
                queryTerms: queryTerms,
                analysis: analysis,
                limit: max(max(candidateLimit, 10) - transcriptUnitHits.count, 0)
            )
            : []
        let artifactHits = artifactEvidenceHits(
            evidenceRows: artifactPerceptions,
            queryTerms: queryTerms,
            analysis: analysis,
            limit: candidateLimit
        )
        let memoryHits = rankedMemorySummaryHits(
            memoryRows,
            queryTerms: queryTerms,
            analysis: analysis,
            limit: candidateLimit
        )

        return rerankedLexicalHits(
            taskSegmentHits + transcriptUnitHits + transcriptHits + artifactHits + memoryHits,
            analysis: analysis,
            limit: limit
        )
    }

    private func loadTaskSegments(
        lookupText: String,
        scope: MemoryQueryScope,
        limit: Int
    ) async -> [TaskSegmentRecord] {
        do {
            return try await database.queryTaskSegments(
                text: lookupText,
                start: scope.start,
                end: scope.end,
                limit: max(limit, 1)
            )
        } catch {
            return []
        }
    }

    private func loadArtifactPerceptions(
        scope: MemoryQueryScope,
        analysis: MemoryQueryQuestionAnalysis,
        anchorSegments: [TaskSegmentRecord],
        limit: Int
    ) async -> [StoredEvidenceRecord] {
        let shouldSearchArtifacts = analysis.prefersLexicalFirst
            || analysis.seeksWorkSummary
            || scope.start != nil
            || scope.end != nil
            || analysis.focusTerms.count >= 2

        guard shouldSearchArtifacts else {
            return []
        }

        let windows: [(start: Date?, end: Date?)]
        if analysis.prefersLexicalFirst {
            windows = evidenceWindows(scope: scope, anchorSegments: anchorSegments)
        } else if scope.start != nil || scope.end != nil {
            windows = [(scope.start, scope.end)]
        } else {
            windows = [(nil, nil)]
        }

        guard !windows.isEmpty else {
            return []
        }

        var rows: [StoredEvidenceRecord] = []
        var seen = Set<String>()

        for window in windows {
            let loaded: [StoredEvidenceRecord]
            do {
                loaded = try await database.listArtifactPerceptionRecords(
                    start: window.start,
                    end: window.end,
                    limit: max(limit, 1)
                )
            } catch {
                continue
            }

            for row in loaded {
                guard seen.insert(row.metadata.id).inserted else { continue }
                guard row.analysis != nil else { continue }
                rows.append(row)
            }
        }

        return rows
    }

    private func loadTranscriptUnits(
        lookupText: String,
        scope: MemoryQueryScope,
        analysis: MemoryQueryQuestionAnalysis,
        anchorSegments: [TaskSegmentRecord],
        limit: Int
    ) async -> [TranscriptUnitRecord] {
        let shouldSearchTranscriptUnits = analysis.prefersLexicalFirst
            || analysis.seeksEvaluation
            || artifactSupport.containsInterviewMarker(lookupText)
        guard shouldSearchTranscriptUnits else {
            return []
        }

        let windows = evidenceWindows(scope: scope, anchorSegments: anchorSegments)
        let effectiveWindows = windows.isEmpty ? [(scope.start, scope.end)] : windows
        var rows: [TranscriptUnitRecord] = []
        var seen = Set<String>()

        for window in effectiveWindows {
            let loaded: [TranscriptUnitRecord]
            do {
                if lookupText.isEmpty {
                    loaded = try await database.listTranscriptUnits(
                        start: window.start,
                        end: window.end,
                        limit: max(limit, 1)
                    )
                } else {
                    loaded = try await database.queryTranscriptUnits(
                        text: lookupText,
                        start: window.start,
                        end: window.end,
                        limit: max(limit, 1)
                    )
                }
            } catch {
                continue
            }

            for row in loaded where seen.insert(row.id).inserted {
                rows.append(row)
            }
        }

        return rows
    }

    private func loadMemorySummaryRows(
        scope: MemoryQueryScope,
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) async -> [MemoryRecord] {
        do {
            let scopedRows = try await database.listMem0MemoryRecords(
                start: scope.start,
                end: scope.end,
                limit: limit
            )
            if !scopedRows.isEmpty || (scope.start == nil && scope.end == nil) {
                return scopedRows
            }

            if analysis.focusTerms.count >= 2 || analysis.seeksWorkSummary {
                return try await database.listMem0MemoryRecords(
                    start: nil,
                    end: nil,
                    limit: max(limit, 64)
                )
            }
            return scopedRows
        } catch {
            return []
        }
    }

    private func rankedTaskSegmentHits(
        _ segments: [TaskSegmentRecord],
        queryTerms: [String],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard !segments.isEmpty else {
            return []
        }

        let docs = segments.map(taskSegmentDocument).map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var output: [MemoryEvidenceHit] = []
        for (index, segment) in segments.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 else { continue }

            let lexicalScore = min(1, rawScore / maxScore)
            let ageHours = Date().timeIntervalSince(segment.occurredAt) / 3600
            let recencyBoost = ageHours < 24 ? 0.05 : (ageHours < 24 * 7 ? 0.03 : 0)
            let confidenceBoost = min(0.08, max(0, segment.confidence * 0.08))
            let metadata = taskSegmentMetadata(segment)
            let boost = metadataMatchBoost(
                text: taskSegmentDocument(segment),
                metadata: metadata,
                analysis: analysis,
                unit: .taskSegment
            )
            let hybridScore = lexicalScore + recencyBoost + confidenceBoost + boost

            output.append(
                MemoryEvidenceHit(
                    id: "task-segment|\(segment.id)",
                    source: .bm25Store,
                    text: taskSegmentSummary(segment),
                    appName: segment.appName?.nilIfEmpty,
                    project: segment.project?.nilIfEmpty,
                    occurredAt: segment.occurredAt,
                    metadata: metadata,
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: hybridScore
                )
            )
        }

        return output
            .sorted(by: hitReranker.lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func rankedMemorySummaryHits(
        _ rows: [MemoryRecord],
        queryTerms: [String],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard !rows.isEmpty else {
            return []
        }

        let docs = rows.map(memorySummaryDocument).map(scopeParser.tokenize)
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
            let metadata: [String: String] = [
                "scope": row.scope,
                "entities": row.entities.joined(separator: "|"),
                "retrieval_unit": LexicalRetrievalUnit.memorySummary.rawValue
            ]
            let boost = metadataMatchBoost(
                text: memorySummaryDocument(row),
                metadata: metadata,
                analysis: analysis,
                unit: .memorySummary
            )

            let key = "memory-summary|\(Int(row.occurredAt.timeIntervalSince1970 / 30))|\(row.summary.prefix(120).lowercased())"
            guard seen.insert(key).inserted else { continue }

            output.append(
                MemoryEvidenceHit(
                    id: key,
                    source: .bm25Store,
                    text: row.summary,
                    appName: row.appName?.nilIfEmpty,
                    project: row.project?.nilIfEmpty,
                    occurredAt: row.occurredAt,
                    metadata: metadata,
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: lexicalScore + recencyBoost + boost
                )
            )
        }

        return output
            .sorted(by: hitReranker.lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func transcriptEvidenceHits(
        evidenceRows: [StoredEvidenceRecord],
        queryTerms: [String],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard limit > 0 else {
            return []
        }
        let candidates = evidenceRows.flatMap { row in
            artifactSupport.transcriptChunks(for: row, analysis: analysis)
        }
        guard !candidates.isEmpty else {
            return []
        }

        let docs = candidates.map(\.document).map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var hits: [MemoryEvidenceHit] = []
        for (index, candidate) in candidates.enumerated() {
            let rawScore = scores[index]
            let lexicalScore = rawScore > 0 ? min(1, rawScore / maxScore) : 0
            let boost = metadataMatchBoost(
                text: candidate.document,
                metadata: candidate.metadata,
                analysis: analysis,
                unit: .transcriptChunk
            )
            let hybridScore = max(lexicalScore, 0.55) + 0.55 + boost

            hits.append(
                MemoryEvidenceHit(
                    id: candidate.id,
                    source: .bm25Store,
                    text: candidate.summary,
                    appName: candidate.appName,
                    project: candidate.project,
                    occurredAt: candidate.occurredAt,
                    metadata: candidate.metadata,
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: hybridScore
                )
            )
        }

        return hits
            .sorted(by: hitReranker.lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func transcriptUnitHits(
        _ units: [TranscriptUnitRecord],
        queryTerms: [String],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        guard limit > 0, !units.isEmpty else {
            return []
        }

        let candidates = units.map { artifactSupport.transcriptUnitCandidate(for: $0) }
        let docs = candidates.map(\.document).map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var hits: [MemoryEvidenceHit] = []
        for (index, candidate) in candidates.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 || candidate.baseScore > 0 else { continue }

            let lexicalScore = rawScore > 0 ? min(1, rawScore / maxScore) : 0
            let boost = metadataMatchBoost(
                text: candidate.document,
                metadata: candidate.metadata,
                analysis: analysis,
                unit: .transcriptUnit
            )
            let hybridScore = max(lexicalScore, 0.58) + candidate.baseScore + boost

            hits.append(
                MemoryEvidenceHit(
                    id: candidate.id,
                    source: .bm25Store,
                    text: candidate.summary,
                    appName: candidate.appName,
                    project: candidate.project,
                    occurredAt: candidate.occurredAt,
                    metadata: candidate.metadata,
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: hybridScore
                )
            )
        }

        return hits
            .sorted(by: hitReranker.lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func artifactEvidenceHits(
        evidenceRows: [StoredEvidenceRecord],
        queryTerms: [String],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        let candidates = evidenceRows.compactMap { row in
            artifactSupport.artifactCandidate(for: row, analysis: analysis)
        }
        guard !candidates.isEmpty else {
            return []
        }

        let docs = candidates.map(\.document).map(scopeParser.tokenize)
        let scores = ranker.score(documents: docs, queryTerms: queryTerms)
        let maxScore = max(scores.max() ?? 0, 0.000_1)

        var hits: [MemoryEvidenceHit] = []
        for (index, candidate) in candidates.enumerated() {
            let rawScore = scores[index]
            guard rawScore > 0 || candidate.baseScore > 0 else { continue }

            let lexicalScore = rawScore > 0 ? min(1, rawScore / maxScore) : 0
            let boost = metadataMatchBoost(
                text: candidate.document,
                metadata: candidate.metadata,
                analysis: analysis,
                unit: .artifactEvidence
            )
            let hybridScore = lexicalScore + candidate.baseScore + boost

            hits.append(
                MemoryEvidenceHit(
                    id: candidate.id,
                    source: .bm25Store,
                    text: candidate.summary,
                    appName: candidate.appName,
                    project: candidate.project,
                    occurredAt: candidate.occurredAt,
                    metadata: candidate.metadata,
                    semanticScore: 0,
                    lexicalScore: lexicalScore,
                    hybridScore: hybridScore
                )
            )
        }

        return hits
            .sorted(by: hitReranker.lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func rerankedLexicalHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        hitReranker.rerankedLexicalHits(hits, analysis: analysis, limit: limit)
    }

    private func metadataMatchBoost(
        text: String,
        metadata: [String: String],
        analysis: MemoryQueryQuestionAnalysis,
        unit: LexicalRetrievalUnit
    ) -> Double {
        hitReranker.metadataMatchBoost(
            text: text,
            metadata: metadata,
            analysis: analysis,
            unit: unit
        )
    }

    private func bestTaskSegmentLookupText(queries: [String], queryTerms: [String]) -> String {
        let exactQuery = queries.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = exactQuery.lowercased()
        let looksNaturalLanguage = exactQuery.contains("?")
            || exactQuery.split(separator: " ").count > 6
            || lowered.hasPrefix("what ")
            || lowered.hasPrefix("how ")
            || lowered.hasPrefix("summar")
            || lowered.hasPrefix("tell me")

        if looksNaturalLanguage {
            return ""
        }
        if !exactQuery.isEmpty {
            return exactQuery
        }
        return queryTerms.joined(separator: " ")
    }

    private func taskSegmentDocument(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.joined(separator: " ")
        let entities = segment.entities.joined(separator: " ")
        var fields: [String] = []
        fields.append(segment.task)
        fields.append(segment.issueOrGoal ?? "")
        fields.append(actions)
        fields.append(segment.outcome ?? "")
        fields.append(segment.nextStep ?? "")
        fields.append(segment.blocker ?? "")
        fields.append(segment.people.joined(separator: " "))
        fields.append(segment.evidenceExcerpts.joined(separator: " "))
        fields.append(segment.summary)
        fields.append(segment.project ?? "")
        fields.append(segment.appName ?? "")
        fields.append(segment.workspace ?? "")
        fields.append(segment.repo ?? "")
        fields.append(segment.document ?? "")
        fields.append(segment.url ?? "")
        fields.append(entities)
        fields.append(segment.status.rawValue)
        fields.append(segment.scope)
        return fields.joined(separator: " ")
    }

    private func taskSegmentSummary(_ segment: TaskSegmentRecord) -> String {
        let actions = segment.actions.prefix(3).joined(separator: "; ")
        let actionsPart = actions.isEmpty ? "" : " | Actions: \(actions)"
        let outcomePart = segment.outcome?.nilIfEmpty.map { " | Outcome: \($0)" } ?? ""
        let nextStepPart = segment.nextStep?.nilIfEmpty.map { " | Next step: \($0)" } ?? ""
        let issuePart = segment.issueOrGoal?.nilIfEmpty.map { " | Issue/Goal: \($0)" } ?? ""
        let projectPart = segment.project?.nilIfEmpty.map { " | Project: \($0)" } ?? ""
        let blockerPart = segment.blocker?.nilIfEmpty.map { " | Blocker: \($0)" } ?? ""
        let peoplePart = segment.people.isEmpty ? "" : " | People: \(segment.people.joined(separator: ", "))"
        return "Task: \(segment.task) | Status: \(segment.status.rawValue)\(issuePart)\(actionsPart)\(outcomePart)\(nextStepPart)\(blockerPart)\(peoplePart)\(projectPart)"
    }

    private func taskSegmentMetadata(_ segment: TaskSegmentRecord) -> [String: String] {
        var metadata: [String: String] = [
            "scope": segment.scope,
            "workspace": segment.workspace ?? "",
            "repo": segment.repo ?? "",
            "document": segment.document ?? "",
            "url": segment.url ?? "",
            "entities": segment.entities.joined(separator: "|"),
            "task_segment_status": segment.status.rawValue,
            "task": segment.task,
            "retrieval_unit": LexicalRetrievalUnit.taskSegment.rawValue
        ]
        if let project = segment.project?.nilIfEmpty {
            metadata["project"] = project
        }
        if let blocker = segment.blocker?.nilIfEmpty {
            metadata["blocker"] = blocker
        }
        if !segment.people.isEmpty {
            metadata["people"] = segment.people.joined(separator: "|")
        }
        if !segment.evidenceExcerpts.isEmpty {
            metadata["evidence_excerpts"] = segment.evidenceExcerpts.joined(separator: "|")
        }
        if !segment.artifactKinds.isEmpty {
            metadata["artifact_kinds"] = segment.artifactKinds.map(\.rawValue).joined(separator: "|")
        }
        if !segment.sourceKinds.isEmpty {
            metadata["source_kinds"] = segment.sourceKinds.map(\.rawValue).joined(separator: "|")
        }
        return metadata
    }

    private func memorySummaryDocument(_ row: MemoryRecord) -> String {
        [
            row.summary,
            row.project ?? "",
            row.appName ?? "",
            row.scope,
            row.entities.joined(separator: " ")
        ].joined(separator: " ")
    }

    private func evidenceWindows(
        scope: MemoryQueryScope,
        anchorSegments: [TaskSegmentRecord]
    ) -> [(start: Date?, end: Date?)] {
        let sortedAnchors = anchorSegments
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)

        let anchorWindows = sortedAnchors.compactMap { segment in
            let start = calendarDate(byAddingMinutes: -10, to: segment.startTime)
            let end = calendarDate(byAddingMinutes: 45, to: segment.endTime)
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

    private func shouldIncludeEvidence(
        _ row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis,
        document: String
    ) -> Bool {
        if row.metadata.kind == .audio {
            return artifactSupport.hasTranscript(row)
        }

        if analysis.prefersLexicalFirst {
            return artifactSupport.containsInterviewMarker(document)
        }
        return true
    }

    private func calendarDate(byAddingMinutes minutes: Int, to date: Date) -> Date? {
        Calendar.autoupdatingCurrent.date(byAdding: .minute, value: minutes, to: date)
    }
}

private extension Array where Element == String {
    func nilIfEmptyJoined(separator: String) -> String? {
        let filtered = compactMap(\.nilIfEmpty)
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: separator)
    }
}
