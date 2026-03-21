import Foundation

struct MemoryQueryRetrievalSupport: Sendable {
    private let heuristicPlanner: MemoryQueryHeuristicPlanner
    private let scopeParser: MemoryQueryScopeParser
    private let calendar: Calendar

    init(
        heuristicPlanner: MemoryQueryHeuristicPlanner,
        scopeParser: MemoryQueryScopeParser,
        calendar: Calendar
    ) {
        self.heuristicPlanner = heuristicPlanner
        self.scopeParser = scopeParser
        self.calendar = calendar
    }

    func normalizedPlanSteps(
        plan: MemoryQueryPlan?,
        originalQuestion: String,
        request: MemoryQueryRequest,
        profile: QueryIntentProfile
    ) -> [MemoryQueryPlanStep] {
        let fallbackSteps = heuristicPlanner.defaultPlanSteps(
            for: originalQuestion,
            requestOptions: request.options,
            profile: profile
        )
        if profile.seeksCallConversation {
            return Array(fallbackSteps.prefix(6))
        }
        let candidateSteps = !(plan?.steps.isEmpty ?? true) ? (plan?.steps ?? []) : fallbackSteps

        var seen = Set<String>()
        var output: [MemoryQueryPlanStep] = []

        for step in candidateSteps {
            let effectiveSources = step.sources.intersection(request.options.sources)
            guard !effectiveSources.isEmpty else { continue }

            let normalized = MemoryQueryPlanStep(
                query: step.query,
                sources: effectiveSources,
                phase: step.phase,
                maxResults: step.maxResults
            )
            let key = stepKey(normalized)
            guard seen.insert(key).inserted else { continue }
            output.append(normalized)
        }

        if output.isEmpty {
            return fallbackSteps
        }
        return Array(output.prefix(8))
    }

    func resolveScope(
        question: String,
        plannerScope: MemoryQueryScope?,
        fallbackScope: MemoryQueryScope
    ) -> MemoryQueryScope {
        if scopeParser.hasExplicitDate(in: question)
            || fallbackScope.start != nil
            || fallbackScope.end != nil {
            return fallbackScope
        }

        guard let plannerScope else {
            return fallbackScope
        }

        let start = plannerScope.start ?? fallbackScope.start
        let end = plannerScope.end ?? fallbackScope.end
        let label = plannerScope.label?.nilIfEmpty ?? fallbackScope.label
        return MemoryQueryScope(start: start, end: end, label: label)
    }

    func plannerQuestion(
        originalQuestion: String,
        pass: Int,
        scope: MemoryQueryScope,
        executedQueries: [String],
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> String {
        guard pass > 1 else {
            return originalQuestion
        }

        let scopeLabel = scope.label?.nilIfEmpty ?? "unspecified"
        let scopeStart = scope.start.map(isoDay) ?? ""
        let scopeEnd = scope.end.map(isoDay) ?? ""
        let priorQueries = executedQueries.prefix(24).map { "- \($0)" }.joined(separator: "\n")

        let evidencePreview: [String] = (mem0Evidence + bm25Evidence)
            .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
            .prefix(24)
            .map { hit in
                let timestamp = hit.occurredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown-time"
                return "- [\(timestamp)] \((hit.appName ?? "unknown-app")) | \(hit.text)"
            }

        let previewText = evidencePreview.isEmpty ? "- none yet" : evidencePreview.joined(separator: "\n")

        return """
        Original question:
        \(originalQuestion)

        Planning pass: \(pass)
        Already executed queries (do not repeat):
        \(priorQueries.isEmpty ? "- none" : priorQueries)

        Current scope: \(scopeLabel)
        Scope start: \(scopeStart)
        Scope end: \(scopeEnd)
        Current evidence counts: mem0=\(mem0Evidence.count), bm25=\(bm25Evidence.count)
        Evidence preview:
        \(previewText)

        Return only new, non-duplicate retrieval steps that fill missing details and chronology gaps.
        Use research steps when fast local reconnaissance would improve later evidence retrieval.
        """
    }

    func retrievalPlan(
        for detailLevel: MemoryQueryDetailLevel,
        requestedMaxResults: Int?,
        enabledSources: Set<MemoryEvidenceSource>
    ) -> MemoryQueryRetrievalPlan {
        let basePlan: MemoryQueryRetrievalPlan
        switch detailLevel {
        case .concise:
            basePlan = MemoryQueryRetrievalPlan(
                semanticLimit: 18,
                lexicalLimit: 18,
                perPassSemanticLimit: 12,
                perPassLexicalLimit: 12,
                maxPlannerPasses: 2,
                targetEvidenceCount: 18,
                minPassesBeforeStop: 1,
                minEvidenceGainPerPass: 1
            )
        case .detailed:
            basePlan = MemoryQueryRetrievalPlan(
                semanticLimit: 32,
                lexicalLimit: 32,
                perPassSemanticLimit: 18,
                perPassLexicalLimit: 18,
                maxPlannerPasses: 3,
                targetEvidenceCount: 32,
                minPassesBeforeStop: 2,
                minEvidenceGainPerPass: 2
            )
        }

        let sourceCount = max(1, enabledSources.count)
        let requestedPerSource = requestedMaxResults.map { max(1, Int(ceil(Double($0) / Double(sourceCount)))) }

        return MemoryQueryRetrievalPlan(
            semanticLimit: enabledSources.contains(.mem0Semantic) ? min(basePlan.semanticLimit, requestedPerSource ?? basePlan.semanticLimit) : 0,
            lexicalLimit: enabledSources.contains(.bm25Store) ? min(basePlan.lexicalLimit, requestedPerSource ?? basePlan.lexicalLimit) : 0,
            perPassSemanticLimit: enabledSources.contains(.mem0Semantic) ? min(basePlan.perPassSemanticLimit, requestedPerSource ?? basePlan.perPassSemanticLimit) : 0,
            perPassLexicalLimit: enabledSources.contains(.bm25Store) ? min(basePlan.perPassLexicalLimit, requestedPerSource ?? basePlan.perPassLexicalLimit) : 0,
            maxPlannerPasses: basePlan.maxPlannerPasses,
            targetEvidenceCount: requestedMaxResults ?? basePlan.targetEvidenceCount,
            minPassesBeforeStop: basePlan.minPassesBeforeStop,
            minEvidenceGainPerPass: basePlan.minEvidenceGainPerPass
        )
    }

    func selectedSemanticQueries(
        from steps: [MemoryQueryPlanStep],
        profile: QueryIntentProfile,
        detailLevel: MemoryQueryDetailLevel
    ) -> [String] {
        if profile.seeksCallConversation {
            return []
        }

        if profile.prefersLexicalFirst,
           steps.contains(where: { $0.sources.contains(.bm25Store) }) {
            return []
        }

        let maxQueries = semanticQueryCap(profile: profile, detailLevel: detailLevel)
        guard maxQueries > 0 else {
            return []
        }

        var seen = Set<String>()
        var queries: [String] = []

        for step in steps where step.sources.contains(.mem0Semantic) {
            let normalized = step.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            queries.append(normalized)
            if queries.count >= maxQueries {
                break
            }
        }

        return queries
    }

    func mergeSemanticHits(
        _ lhs: [MemoryEvidenceHit],
        _ rhs: [MemoryEvidenceHit],
        limit: Int
    ) -> [MemoryEvidenceHit] {
        var merged = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for hit in rhs {
            if let existing = merged[hit.id], existing.semanticScore >= hit.semanticScore {
                continue
            }
            merged[hit.id] = hit
        }

        return merged.values
            .sorted {
                if abs($0.semanticScore - $1.semanticScore) > 0.0001 {
                    return $0.semanticScore > $1.semanticScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    func mergeLexicalHits(
        _ lhs: [MemoryEvidenceHit],
        _ rhs: [MemoryEvidenceHit],
        limit: Int
    ) -> [MemoryEvidenceHit] {
        var merged = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for hit in rhs {
            if let existing = merged[hit.id], existing.hybridScore >= hit.hybridScore {
                continue
            }
            merged[hit.id] = hit
        }

        return merged.values
            .sorted {
                if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                    return $0.hybridScore > $1.hybridScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    func shouldSwitchToFullContextMode(
        scope: MemoryQueryScope,
        profile: QueryIntentProfile,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> Bool {
        let combinedCount = mem0Evidence.count + bm25Evidence.count
        guard combinedCount > 0 else {
            return false
        }

        let directLocalEvidence = bm25Evidence.filter {
            guard let unit = $0.metadata["retrieval_unit"] else { return false }
            return unit == "task_segment" || unit == "transcript_chunk" || unit == "transcript_unit" || unit == "artifact_evidence"
        }
        guard !directLocalEvidence.isEmpty else {
            return false
        }

        let scopedDuration: TimeInterval? = {
            guard let start = scope.start, let end = scope.end else { return nil }
            return max(0, end.timeIntervalSince(start))
        }()

        if profile.prefersLexicalFirst,
           hasTranscriptCoverage(in: bm25Evidence),
           directLocalEvidence.count <= 18 {
            return true
        }

        if profile.seeksWorkSummary,
           let scopedDuration,
           scopedDuration <= 60 * 60 * 48,
           directLocalEvidence.count <= 16 {
            return true
        }

        if let scopedDuration,
           scopedDuration <= 60 * 60 * 12,
           combinedCount <= 12 {
            return true
        }

        return false
    }

    private func stepKey(_ step: MemoryQueryPlanStep) -> String {
        let sources = step.sources.map(\.rawValue).sorted().joined(separator: ",")
        return "\(step.phase.rawValue)|\(sources)|\(step.query.lowercased())"
    }

    private func semanticQueryCap(
        profile: QueryIntentProfile,
        detailLevel: MemoryQueryDetailLevel
    ) -> Int {
        switch (profile.prefersLexicalFirst, detailLevel) {
        case (true, .detailed):
            return 3
        case (true, .concise):
            return 2
        case (false, .detailed):
            return 4
        case (false, .concise):
            return 3
        }
    }

    private func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func hasTranscriptCoverage(in evidence: [MemoryEvidenceHit]) -> Bool {
        evidence.filter { hit in
            hit.metadata["artifact_kind"] == ArtifactKind.audio.rawValue
                && hit.metadata["has_transcript"] == "true"
        }.count >= 2
    }
}

struct MemoryQueryRetrievalPlan: Sendable {
    let semanticLimit: Int
    let lexicalLimit: Int
    let perPassSemanticLimit: Int
    let perPassLexicalLimit: Int
    let maxPlannerPasses: Int
    let targetEvidenceCount: Int
    let minPassesBeforeStop: Int
    let minEvidenceGainPerPass: Int
}

struct StepExecutionOutput: Sendable {
    var mem0Hits: [MemoryEvidenceHit] = []
    var bm25Hits: [MemoryEvidenceHit] = []
}
