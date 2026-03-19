import Foundation

final class SQLiteBM25MemoryRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let database: SQLiteStore
    private let ranker: BM25Ranker
    private let scopeParser: MemoryQueryScopeParser
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer

    private let transcriptIndicators = ["transcript", "interview", "meeting", "zoom", "call", "candidate", "notetaker"]
    private let interviewMarkers = ["interview", "candidate", "metaview", "notetaker", "zoom"]
    private let metaNoiseIndicators = ["telegram reminder", "analyze the transcript later", "remind me", "follow up later", "todo", "later analysis"]
    init(
        database: SQLiteStore,
        ranker: BM25Ranker,
        scopeParser: MemoryQueryScopeParser
    ) {
        self.database = database
        self.ranker = ranker
        self.scopeParser = scopeParser
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: scopeParser)
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
            || containsInterviewMarker(lookupText)
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
            .sorted(by: lexicalHitSort)
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
            .sorted(by: lexicalHitSort)
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
            transcriptChunks(for: row, analysis: analysis)
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
            .sorted(by: lexicalHitSort)
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

        let candidates = units.map { transcriptUnitCandidate(for: $0) }
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
            .sorted(by: lexicalHitSort)
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
            artifactCandidate(for: row, analysis: analysis)
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
            .sorted(by: lexicalHitSort)
            .prefix(limit)
            .map { $0 }
    }

    private func transcriptChunks(
        for row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis
    ) -> [ArtifactCandidate] {
        guard hasTranscript(row) else {
            return []
        }
        let document = evidenceDocument(row)
        guard shouldIncludeEvidence(row, analysis: analysis, document: document) else {
            return []
        }

        let transcript = row.analysis?.transcript?.nilIfEmpty ?? ""
        let segments = chunkTranscript(transcript)
        let summary = row.analysis?.summary.nilIfEmpty ?? row.analysis?.description ?? "Retrieved transcript evidence"
        let project = row.analysis?.project?.nilIfEmpty ?? row.metadata.window.project?.nilIfEmpty
        let task = row.analysis?.task?.nilIfEmpty
        let workspace = row.analysis?.workspace?.nilIfEmpty ?? row.metadata.window.workspace?.nilIfEmpty
        let title = row.metadata.window.title?.nilIfEmpty

        var candidates: [ArtifactCandidate] = []
        for (index, segment) in segments.enumerated() {
            let normalizedSegment = segment
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerLabels = Set(
                matches(
                    pattern: "S\\d+:",
                    in: normalizedSegment
                ).map { $0.lowercased() }
            )
            let hasSpeakerWindow = !speakerLabels.isEmpty
            let isExchange = speakerLabels.count >= 2
            var metadata: [String: String] = [
                "scope": "evidence",
                "artifact_kind": row.metadata.kind.rawValue,
                "capture_reason": row.metadata.captureReason,
                "window_title": title ?? "",
                "workspace": workspace ?? "",
                "task": task ?? "",
                "has_transcript": "true",
                "retrieval_unit": LexicalRetrievalUnit.transcriptChunk.rawValue,
                "transcript_chunk_index": String(index)
            ]
            if let project {
                metadata["project"] = project
            }
            if let entities = row.analysis?.entities.nilIfEmptyJoined(separator: "|") {
                metadata["entities"] = entities
            }
            if hasSpeakerWindow {
                metadata["speaker_turn_window"] = "true"
            }
            if isExchange {
                metadata["speaker_exchange"] = "true"
            }

            var contextualParts: [String] = []
            let transcriptLabel = isExchange ? "Transcript exchange" : "Transcript excerpt"
            contextualParts.append("\(transcriptLabel): \(normalizedSegment)")
            if let task {
                contextualParts.append("Task: \(task)")
            }
            if let project {
                contextualParts.append("Project: \(project)")
            }
            if let workspace {
                contextualParts.append("Workspace: \(workspace)")
            }
            if let title {
                contextualParts.append("Window title: \(title)")
            }
            contextualParts.append("Summary: \(summary)")
            if let extraEvidence = row.analysis?.evidence.joined(separator: " ").nilIfEmpty {
                contextualParts.append(extraEvidence)
            }
            let groundedSummary = contextualParts.joined(separator: " | ")
            let contextualDocument = contextualParts.joined(separator: " | ")

            candidates.append(
                ArtifactCandidate(
                    id: "evidence|\(row.metadata.id)|chunk|\(index)",
                    appName: row.metadata.app.appName.nilIfEmpty,
                    project: project,
                    occurredAt: row.metadata.capturedAt,
                    document: contextualDocument,
                    summary: groundedSummary,
                    metadata: metadata,
                    baseScore: 0.18
                )
            )
        }

        return candidates
    }

    private func artifactCandidate(
        for row: StoredEvidenceRecord,
        analysis: MemoryQueryQuestionAnalysis
    ) -> ArtifactCandidate? {
        guard let rowAnalysis = row.analysis else {
            return nil
        }
        if analysis.prefersLexicalFirst, hasTranscript(row) {
            return nil
        }

        let document = evidenceDocument(row)
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let summary = artifactSummary(row)
        let project = rowAnalysis.project?.nilIfEmpty ?? row.metadata.window.project?.nilIfEmpty
        let workspace = rowAnalysis.workspace?.nilIfEmpty ?? row.metadata.window.workspace?.nilIfEmpty
        let task = rowAnalysis.task?.nilIfEmpty
        let title = row.metadata.window.title?.nilIfEmpty

        var metadata: [String: String] = [
            "scope": "evidence",
            "artifact_kind": row.metadata.kind.rawValue,
            "capture_reason": row.metadata.captureReason,
            "window_title": title ?? "",
            "workspace": workspace ?? "",
            "task": task ?? "",
            "retrieval_unit": LexicalRetrievalUnit.artifactEvidence.rawValue
        ]
        if let project {
            metadata["project"] = project
        }
        if let entities = rowAnalysis.entities.nilIfEmptyJoined(separator: "|") {
            metadata["entities"] = entities
        }
        if rowAnalysis.status != .none {
            metadata["artifact_status"] = rowAnalysis.status.rawValue
        }

        var baseScore = row.metadata.kind == .screenshot ? 0.18 : 0.12
        if rowAnalysis.status == .blocked {
            baseScore += 0.08
        }
        if isMetaNoise(document) {
            baseScore -= 0.2
        }

        return ArtifactCandidate(
            id: "evidence|\(row.metadata.id)",
            appName: row.metadata.app.appName.nilIfEmpty,
            project: project,
            occurredAt: row.metadata.capturedAt,
            document: document,
            summary: summary,
            metadata: metadata,
            baseScore: baseScore
        )
    }

    private func transcriptUnitCandidate(for unit: TranscriptUnitRecord) -> ArtifactCandidate {
        let isExchange = unit.kind == .speakerExchange
        var metadata: [String: String] = [
            "scope": "transcript_unit",
            "artifact_kind": ArtifactKind.audio.rawValue,
            "has_transcript": "true",
            "task": unit.task ?? "",
            "workspace": unit.workspace ?? "",
            "retrieval_unit": LexicalRetrievalUnit.transcriptUnit.rawValue,
            "transcript_unit_kind": unit.kind.rawValue
        ]
        if let project = unit.project?.nilIfEmpty {
            metadata["project"] = project
        }
        if let appName = unit.appName?.nilIfEmpty {
            metadata["app_name"] = appName
        }
        if let sessionID = unit.sessionID?.nilIfEmpty {
            metadata["session_id"] = sessionID
        }
        if let speakerLabel = unit.speakerLabel?.nilIfEmpty {
            metadata["speaker_label"] = speakerLabel
        }
        if !unit.topicTags.isEmpty {
            metadata["topic_tags"] = unit.topicTags.joined(separator: "|")
        }
        if !unit.people.isEmpty {
            metadata["people"] = unit.people.joined(separator: "|")
        }
        if !unit.entities.isEmpty {
            metadata["entities"] = unit.entities.joined(separator: "|")
        }
        if isExchange {
            metadata["speaker_exchange"] = "true"
            metadata["speaker_turn_window"] = "true"
        }

        var contextualParts: [String] = []
        contextualParts.append(isExchange ? "Transcript exchange: \(unit.excerptText)" : "Transcript excerpt: \(unit.excerptText)")
        contextualParts.append("Summary: \(unit.summary)")
        if let task = unit.task?.nilIfEmpty {
            contextualParts.append("Task: \(task)")
        }
        if let project = unit.project?.nilIfEmpty {
            contextualParts.append("Project: \(project)")
        }
        if let workspace = unit.workspace?.nilIfEmpty {
            contextualParts.append("Workspace: \(workspace)")
        }
        if !unit.topicTags.isEmpty {
            contextualParts.append("Topics: \(unit.topicTags.prefix(6).joined(separator: ", "))")
        }
        if !unit.people.isEmpty {
            contextualParts.append("People: \(unit.people.joined(separator: ", "))")
        }

        return ArtifactCandidate(
            id: "transcript-unit|\(unit.id)",
            appName: unit.appName?.nilIfEmpty,
            project: unit.project?.nilIfEmpty,
            occurredAt: unit.occurredAt,
            document: contextualParts.joined(separator: " | "),
            summary: contextualParts.prefix(4).joined(separator: " | "),
            metadata: metadata,
            baseScore: isExchange ? 0.88 : 0.72
        )
    }

    private func rerankedLexicalHits(
        _ hits: [MemoryEvidenceHit],
        analysis: MemoryQueryQuestionAnalysis,
        limit: Int
    ) -> [MemoryEvidenceHit] {
        hits
            .sorted { lhs, rhs in
                let lhsScore = rerankScore(lhs, analysis: analysis)
                let rhsScore = rerankScore(rhs, analysis: analysis)
                if abs(lhsScore - rhsScore) > 0.0001 {
                    return lhsScore > rhsScore
                }
                return lexicalHitSort(lhs, rhs)
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

    private func rerankScore(
        _ hit: MemoryEvidenceHit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        var score = hit.hybridScore
        let unit = LexicalRetrievalUnit(rawValue: hit.metadata["retrieval_unit"] ?? "") ?? .memorySummary
        score += corpusBoost(unit: unit, analysis: analysis)

        if analysis.prefersLexicalFirst, unit == .transcriptChunk {
            score += 0.95
        }
        if analysis.prefersLexicalFirst, unit == .transcriptUnit {
            score += 1.15
        }
        if analysis.seeksWorkSummary, unit == .taskSegment {
            score += 0.45
        }
        if analysis.prefersLexicalFirst,
           unit != .transcriptChunk && unit != .transcriptUnit {
            score -= analysis.seeksEvaluation ? 0.45 : 0.18
        }
        if analysis.seeksEvaluation {
            if unit == .transcriptChunk || unit == .transcriptUnit {
                score += 0.35
            } else if unit == .taskSegment {
                score -= 0.1
            } else {
                score -= 0.3
            }
        }
        if hit.metadata["speaker_turn_window"] == "true" {
            score += 0.15
        }
        if hit.metadata["speaker_exchange"] == "true" {
            score += 0.2
        }
        if isMetaNoise(evidenceText(hit)), analysis.prefersLexicalFirst || analysis.seeksWorkSummary {
            score -= 1.25
        }

        return score
    }

    private func corpusBoost(
        unit: LexicalRetrievalUnit,
        analysis: MemoryQueryQuestionAnalysis
    ) -> Double {
        switch unit {
        case .taskSegment:
            return analysis.seeksWorkSummary ? 0.45 : 0.25
        case .transcriptUnit:
            return analysis.prefersLexicalFirst ? 0.82 : 0.2
        case .transcriptChunk:
            return analysis.prefersLexicalFirst ? 0.6 : 0.15
        case .artifactEvidence:
            return analysis.seeksWorkSummary ? 0.2 : 0.12
        case .memorySummary:
            return 0.05
        }
    }

    private func metadataMatchBoost(
        text: String,
        metadata: [String: String],
        analysis: MemoryQueryQuestionAnalysis,
        unit: LexicalRetrievalUnit
    ) -> Double {
        let loweredText = text.lowercased()
        let searchableMetadata = metadata.values.joined(separator: " ").lowercased()
        let structuralMetadata = [
            metadata["project"],
            metadata["repo"],
            metadata["workspace"],
            metadata["task"]
        ]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " ")
        .lowercased()
        var boost = 0.0
        var focusMatches = 0
        var structuralFocusMatches = 0

        for focus in analysis.focusTerms {
            if structuralMetadata.contains(focus) {
                focusMatches += 1
                structuralFocusMatches += 1
                boost += 0.45
            } else if searchableMetadata.contains(focus) {
                focusMatches += 1
                boost += 0.32
            } else if loweredText.contains(focus) {
                focusMatches += 1
                boost += 0.2
            }
        }

        if !analysis.focusTerms.isEmpty && focusMatches == 0 {
            boost -= unit == .memorySummary ? 0.15 : 0.3
        }
        if analysis.seeksWorkSummary,
           !analysis.focusTerms.isEmpty,
           structuralFocusMatches == 0 {
            switch unit {
            case .taskSegment:
                boost -= 0.05
            case .artifactEvidence:
                boost -= 0.35
            case .memorySummary:
                boost -= 0.2
            case .transcriptChunk, .transcriptUnit:
                break
            }
        }

        for dimension in analysis.requestedDimensions {
            let tokens = dimensionTokens(dimension)
            let matches = tokens.filter { loweredText.contains($0) || searchableMetadata.contains($0) }.count
            boost += Double(matches) * 0.08
        }

        if analysis.seeksEvaluation, unit == .transcriptChunk || unit == .transcriptUnit {
            boost += 0.15
        }
        if analysis.seeksEvaluation,
           (unit == .transcriptChunk || unit == .transcriptUnit),
           (loweredText.contains("s1:") || loweredText.contains("s2:")) {
            boost += 0.12
        }
        if analysis.seeksWorkSummary, unit == .taskSegment {
            boost += 0.1
        }

        return boost
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
            return hasTranscript(row)
        }

        if analysis.prefersLexicalFirst {
            return containsInterviewMarker(document)
        }
        return true
    }

    private func evidenceDocument(_ row: StoredEvidenceRecord) -> String {
        let analysis = row.analysis
        let summary = analysis?.summary ?? ""
        let transcript = analysis?.transcript ?? ""
        let description = analysis?.description ?? ""
        let contentDescription = analysis?.contentDescription ?? ""
        let problem = analysis?.problem ?? ""
        let success = analysis?.success ?? ""
        let contribution = analysis?.userContribution ?? ""
        let decision = analysis?.suggestionOrDecision ?? ""
        let task = analysis?.task ?? ""
        let project = analysis?.project ?? ""
        let workspace = analysis?.workspace ?? ""
        let title = row.metadata.window.title ?? ""
        let windowProject = row.metadata.window.project ?? ""
        let windowWorkspace = row.metadata.window.workspace ?? ""
        let appName = row.metadata.app.appName
        let entities = analysis?.entities.joined(separator: " ") ?? ""
        let salientText = analysis?.salientText.joined(separator: " ") ?? ""
        let evidence = analysis?.evidence.joined(separator: " ") ?? ""
        let fields = [
            summary,
            transcript,
            description,
            contentDescription,
            problem,
            success,
            contribution,
            decision,
            task,
            project,
            workspace,
            title,
            windowProject,
            windowWorkspace,
            appName,
            entities,
            salientText,
            evidence
        ]
        return fields.joined(separator: " ")
    }

    private func artifactSummary(_ row: StoredEvidenceRecord) -> String {
        let analysis = row.analysis
        var fragments: [String] = []
        if let summary = analysis?.summary.nilIfEmpty ?? analysis?.description.nilIfEmpty {
            fragments.append(summary)
        }
        if let contentDescription = analysis?.contentDescription.nilIfEmpty,
           contentDescription != analysis?.description.nilIfEmpty {
            fragments.append(contentDescription)
        }
        if let task = analysis?.task?.nilIfEmpty {
            fragments.append("Task: \(task)")
        }
        if let decision = analysis?.suggestionOrDecision?.nilIfEmpty {
            fragments.append("Decision: \(decision)")
        }
        if let problem = analysis?.problem?.nilIfEmpty {
            fragments.append("Problem: \(problem)")
        }
        if let success = analysis?.success?.nilIfEmpty {
            fragments.append("Success: \(success)")
        }
        if let salient = analysis?.salientText.prefix(4), !salient.isEmpty {
            fragments.append("Visible: \(salient.joined(separator: "; "))")
        }
        return fragments.joined(separator: " | ").nilIfEmpty ?? "Retrieved evidence"
    }

    private func hasTranscript(_ row: StoredEvidenceRecord) -> Bool {
        row.analysis?.transcript?.nilIfEmpty != nil
    }

    private func containsInterviewMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return interviewMarkers.contains { lowered.contains($0) }
    }

    private func chunkTranscript(_ transcript: String) -> [String] {
        let collapsed = transcript
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return []
        }

        let speakerWindows = speakerTurnWindows(from: collapsed)
        if !speakerWindows.isEmpty {
            return speakerWindows
        }

        let pieces = collapsed
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.components(separatedBy: "|")
            }
            .flatMap { piece in
                piece.split(whereSeparator: { ".!?".contains($0) }).map(String.init)
            }
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else {
            return [collapsed]
        }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : "\(current). \(piece)"
            if candidate.count <= 280 {
                current = candidate
                continue
            }

            if !current.isEmpty {
                chunks.append(current)
            }
            current = piece
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.isEmpty ? [collapsed] : chunks
    }

    private func speakerTurnWindows(from transcript: String) -> [String] {
        let turns = speakerTurns(from: transcript)
        guard !turns.isEmpty else {
            return []
        }
        guard turns.count > 1 else {
            return turns
        }

        var windows: [String] = []
        var seen = Set<String>()

        func appendWindow(_ value: String) {
            let normalized = value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard normalized.count <= 520 else { return }
            guard seen.insert(normalized).inserted else { return }
            windows.append(normalized)
        }

        for index in turns.indices {
            if index + 1 < turns.count {
                appendWindow("\(turns[index]) \(turns[index + 1])")
            }
            if index + 2 < turns.count {
                appendWindow("\(turns[index]) \(turns[index + 1]) \(turns[index + 2])")
            }
        }

        return windows.isEmpty ? turns : windows
    }

    private func speakerTurns(from transcript: String) -> [String] {
        let pattern = "(S\\d+:.*?)(?=(?:\\s*S\\d+:)|$)"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let nsrange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let matches = regex.matches(in: transcript, options: [], range: nsrange)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: transcript) else {
                return nil
            }
            return transcript[range]
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: ":"))))
        }
    }

    private func evidenceText(_ hit: MemoryEvidenceHit) -> String {
        (
            hit.text
            + " "
            + (hit.appName ?? "")
            + " "
            + (hit.project ?? "")
            + " "
            + hit.metadata.values.joined(separator: " ")
        ).lowercased()
    }

    private func dimensionTokens(_ dimension: String) -> [String] {
        dimension
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    private func lexicalHitSort(_ lhs: MemoryEvidenceHit, _ rhs: MemoryEvidenceHit) -> Bool {
        if abs(lhs.hybridScore - rhs.hybridScore) > 0.0001 {
            return lhs.hybridScore > rhs.hybridScore
        }
        return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
    }

    private func isMetaNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return metaNoiseIndicators.contains { lowered.contains($0) }
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func calendarDate(byAddingMinutes minutes: Int, to date: Date) -> Date? {
        Calendar.autoupdatingCurrent.date(byAdding: .minute, value: minutes, to: date)
    }
}

private enum LexicalRetrievalUnit: String {
    case taskSegment = "task_segment"
    case transcriptUnit = "transcript_unit"
    case transcriptChunk = "transcript_chunk"
    case artifactEvidence = "artifact_evidence"
    case memorySummary = "memory_summary"
}

private struct ArtifactCandidate {
    let id: String
    let appName: String?
    let project: String?
    let occurredAt: Date?
    let document: String
    let summary: String
    let metadata: [String: String]
    let baseScore: Double
}

private extension Array where Element == String {
    func nilIfEmptyJoined(separator: String) -> String? {
        let filtered = compactMap(\.nilIfEmpty)
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: separator)
    }
}
