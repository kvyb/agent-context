import Foundation

final class MemoryQueryUseCase: @unchecked Sendable {
    private let maxApproximateResponseTokens = 2_000
    private let semanticRetriever: SemanticMemoryRetrieving
    private let lexicalRetriever: LexicalMemoryRetrieving
    private let planner: MemoryQueryPlanning
    private let answerer: MemoryQueryAnswering
    private let usageWriter: UsageEventWriting
    private let scopeParser: MemoryQueryScopeParser
    private let runtimeConfig: MemoryQueryRuntimeConfig
    private let calendar: Calendar
    private let heuristicPlanner: MemoryQueryHeuristicPlanner
    private let fallbackAnswerBuilder: MemoryQueryFallbackAnswerBuilder
    private let referenceDateProvider: @Sendable () -> Date

    init(
        semanticRetriever: SemanticMemoryRetrieving,
        lexicalRetriever: LexicalMemoryRetrieving,
        planner: MemoryQueryPlanning,
        answerer: MemoryQueryAnswering,
        usageWriter: UsageEventWriting,
        scopeParser: MemoryQueryScopeParser,
        runtimeConfig: MemoryQueryRuntimeConfig,
        calendar: Calendar = .autoupdatingCurrent,
        referenceDateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.semanticRetriever = semanticRetriever
        self.lexicalRetriever = lexicalRetriever
        self.planner = planner
        self.answerer = answerer
        self.usageWriter = usageWriter
        self.scopeParser = scopeParser
        self.runtimeConfig = runtimeConfig
        self.calendar = calendar
        self.heuristicPlanner = MemoryQueryHeuristicPlanner(scopeParser: scopeParser)
        self.fallbackAnswerBuilder = MemoryQueryFallbackAnswerBuilder(calendar: calendar)
        self.referenceDateProvider = referenceDateProvider
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        await executeDetailed(request: request).result
    }

    func executeDetailed(request: MemoryQueryRequest) async -> MemoryQueryExecutionTrace {
        let trimmed = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trace(
                result: emptyQueryResult(for: request.question),
                mem0Evidence: [],
                bm25Evidence: [],
                detailLevel: .concise,
                fullContextMode: false,
                answerOrigin: .failure
            )
        }

        let now = referenceDateProvider()
        let timeZone = calendar.timeZone
        let fallbackScope = request.options.scopeOverride ?? scopeParser.inferScope(for: trimmed, referenceDate: now)
        let deadline = overallDeadline(for: request.options)
        let queryProfile = heuristicPlanner.profile(for: trimmed)

        var detailLevel: MemoryQueryDetailLevel = queryProfile.prefersDetailedAnswer ? .detailed : .concise
        var scope = fallbackScope
        var mem0Evidence: [MemoryEvidenceHit] = []
        var bm25Evidence: [MemoryEvidenceHit] = []
        var executedQueryKeys = Set<String>()
        var executedQueries: [String] = []
        var previousEvidenceCount = 0
        var fullContextMode = false

        let absoluteMaxPasses = 3
        for pass in 1...absoluteMaxPasses {
            guard remainingSeconds(until: deadline) > 0 else {
                request.onProgress?("Query time budget exhausted; returning best partial result.")
                break
            }

            let planningQuestion = plannerQuestion(
                originalQuestion: trimmed,
                pass: pass,
                scope: scope,
                executedQueries: executedQueries,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            )

            let plannerTimeout = stageBudget(
                preferred: runtimeConfig.plannerTimeoutSeconds,
                deadline: deadline,
                reserveSeconds: plannerReserveSeconds(request: request, profile: queryProfile)
            )
            let plannerResult: MemoryQueryPlanResult?
            if let plannerTimeout, plannerTimeout < 1 {
                plannerResult = nil
            } else {
                let plannerBudgetLabel = plannerTimeout.map { formattedSeconds($0) } ?? "no stage cap"
                request.onProgress?("Planning retrieval pass \(pass) (\(plannerBudgetLabel) budget)...")
                plannerResult = await planner.plan(
                    question: planningQuestion,
                    now: now,
                    detailLevel: detailLevel,
                    timeZone: timeZone,
                    timeoutSeconds: plannerTimeout
                )
            }

            let effectivePlannerResult: MemoryQueryPlanResult?
            if let plannerResult {
                effectivePlannerResult = plannerResult
            } else if request.options.allowFallbacks {
                effectivePlannerResult = heuristicPlanner.fallbackPlanResult(
                    for: trimmed,
                    fallbackScope: fallbackScope,
                    detailLevel: detailLevel,
                    requestOptions: request.options
                )
            } else {
                effectivePlannerResult = nil
            }

            if let usage = plannerResult?.usage {
                await usageWriter.appendUsageEvent(usage)
            } else if pass == 1 {
                if request.options.allowFallbacks {
                    request.onProgress?("Planner unavailable; using heuristic local query planner.")
                } else {
                    request.onProgress?("Planner unavailable and fallback is disabled.")
                }
            }

            if effectivePlannerResult == nil {
                return trace(
                    result: failureResult(
                        for: trimmed,
                        scope: scope,
                        message: "The query agent could not produce a retrieval plan within the allotted budget, and fallback planning is disabled."
                    ),
                    mem0Evidence: mem0Evidence,
                    bm25Evidence: bm25Evidence,
                    detailLevel: detailLevel,
                    fullContextMode: fullContextMode,
                    answerOrigin: .failure
                )
            }

            if let plannedLevel = effectivePlannerResult?.plan.detailLevel {
                detailLevel = plannedLevel
            }

            if request.options.scopeOverride == nil {
                scope = resolvedScope(
                    question: trimmed,
                    plannerScope: effectivePlannerResult?.plan.scope,
                    fallbackScope: fallbackScope
                )
            }

            let plannedSteps = normalizedPlanSteps(
                plan: effectivePlannerResult?.plan,
                originalQuestion: trimmed,
                request: request,
                profile: queryProfile
            )
            let freshSteps = plannedSteps.filter { step in
                let key = stepKey(step)
                return executedQueryKeys.insert(key).inserted
            }
            freshSteps.forEach { executedQueries.append($0.query) }
            guard !freshSteps.isEmpty else { break }

            let effectivePlan = retrievalPlan(
                for: detailLevel,
                requestedMaxResults: request.options.maxResults,
                enabledSources: request.options.sources
            )
            let phaseResults = await executePlannedSteps(
                freshSteps,
                scope: scope,
                detailLevel: detailLevel,
                retrievalPlan: effectivePlan,
                deadline: deadline,
                request: request,
                profile: queryProfile
            )
            mem0Evidence = mergeMem0(mem0Evidence, phaseResults.mem0Hits, limit: effectivePlan.semanticLimit)
            bm25Evidence = mergeBM25(bm25Evidence, phaseResults.bm25Hits, limit: effectivePlan.lexicalLimit)

            let totalEvidenceCount = mem0Evidence.count + bm25Evidence.count
            let gained = totalEvidenceCount - previousEvidenceCount
            previousEvidenceCount = totalEvidenceCount

            if shouldSwitchToFullContextMode(
                scope: scope,
                profile: queryProfile,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            ) {
                fullContextMode = true
                request.onProgress?("Scoped evidence corpus is small and direct; preserving the remaining budget for full-context synthesis.")
                break
            }

            if queryProfile.prefersLexicalFirst, hasTranscriptCoverage(in: bm25Evidence) {
                request.onProgress?("Captured transcript evidence locally; preserving remaining budget for answer synthesis.")
                fullContextMode = shouldSwitchToFullContextMode(
                    scope: scope,
                    profile: queryProfile,
                    mem0Evidence: mem0Evidence,
                    bm25Evidence: bm25Evidence
                )
                break
            }

            if pass >= effectivePlan.maxPlannerPasses { break }
            if totalEvidenceCount >= effectivePlan.targetEvidenceCount { break }
            if pass >= effectivePlan.minPassesBeforeStop && gained <= effectivePlan.minEvidenceGainPerPass {
                break
            }
        }

        guard !mem0Evidence.isEmpty || !bm25Evidence.isEmpty else {
            return trace(
                result: noMatchesResult(for: trimmed, scope: scope),
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence,
                detailLevel: detailLevel,
                fullContextMode: fullContextMode,
                answerOrigin: .failure
            )
        }

        let answerOutput = await resolveAnswerPayload(
            question: trimmed,
            scope: scope,
            detailLevel: detailLevel,
            now: now,
            timeZone: timeZone,
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence,
            fullContextMode: fullContextMode,
            deadline: deadline,
            request: request
        )
        let payload = boundedPayload(answerOutput.payload)

        return trace(
            result: MemoryQueryResult(
                query: trimmed,
                answer: payload.answer,
                keyPoints: payload.keyPoints,
                supportingEvents: payload.supportingEvents,
                insufficientEvidence: payload.insufficientEvidence,
                mem0SemanticCount: mem0Evidence.count,
                bm25StoreCount: bm25Evidence.count,
                scope: scope,
                generatedAt: Date()
            ),
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence,
            detailLevel: detailLevel,
            fullContextMode: fullContextMode,
            answerOrigin: answerOutput.origin
        )
    }

    private func emptyQueryResult(for query: String) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: "Enter a question to query memory.",
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            bm25StoreCount: 0,
            scope: MemoryQueryScope(start: nil, end: nil, label: nil),
            generatedAt: Date()
        )
    }

    private func noMatchesResult(for query: String, scope: MemoryQueryScope) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: "No matching memories found in the enabled memory sources.",
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            bm25StoreCount: 0,
            scope: scope,
            generatedAt: Date()
        )
    }

    private func failureResult(for query: String, scope: MemoryQueryScope, message: String) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: message,
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            bm25StoreCount: 0,
            scope: scope,
            generatedAt: Date()
        )
    }

    private func trace(
        result: MemoryQueryResult,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit],
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        answerOrigin: MemoryQueryAnswerOrigin
    ) -> MemoryQueryExecutionTrace {
        MemoryQueryExecutionTrace(
            result: result,
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence,
            detailLevel: detailLevel,
            fullContextMode: fullContextMode,
            answerOrigin: answerOrigin
        )
    }

    private func boundedPayload(_ payload: MemoryQueryAnswerPayload) -> MemoryQueryAnswerPayload {
        var answer = payload.answer
        var keyPoints = payload.keyPoints
        var supportingEvents = payload.supportingEvents

        while approximateTokenCount(
            answer: answer,
            keyPoints: keyPoints,
            supportingEvents: supportingEvents
        ) > maxApproximateResponseTokens {
            if !supportingEvents.isEmpty {
                supportingEvents.removeLast()
                continue
            }
            if !keyPoints.isEmpty {
                keyPoints.removeLast()
                continue
            }
            let trimmed = trimmedText(answer, targetTokenBudget: maxApproximateResponseTokens - 64)
            if trimmed == answer {
                break
            }
            answer = trimmed
        }

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: keyPoints,
            supportingEvents: supportingEvents,
            insufficientEvidence: payload.insufficientEvidence
        )
    }

    private func approximateTokenCount(
        answer: String,
        keyPoints: [String],
        supportingEvents: [String]
    ) -> Int {
        let aggregate = ([answer] + keyPoints + supportingEvents).joined(separator: "\n")
        return max(1, Int(ceil(Double(aggregate.count) / 4.0)))
    }

    private func trimmedText(_ text: String, targetTokenBudget: Int) -> String {
        let targetCharacters = max(160, targetTokenBudget * 4)
        guard text.count > targetCharacters else {
            return text
        }

        let cutoffIndex = text.index(text.startIndex, offsetBy: targetCharacters)
        let prefix = String(text[..<cutoffIndex])
        let candidate = prefix
            .split(separator: " ")
            .dropLast()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? String(prefix) : candidate + "..."
    }

    private func resolveAnswerPayload(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit],
        fullContextMode: Bool,
        deadline: Date?,
        request: MemoryQueryRequest
    ) async -> ResolvedAnswerPayload {
        let answerTimeout = stageBudget(
            preferred: runtimeConfig.answerTimeoutSeconds,
            deadline: deadline,
            reserveSeconds: 0
        )
        if let answerTimeout {
            if answerTimeout >= 1 {
                request.onProgress?("Synthesizing answer (\(formattedSeconds(answerTimeout)) budget)...")
            }
        } else {
            request.onProgress?("Synthesizing answer (no stage cap)...")
        }

        if (answerTimeout ?? 1) >= 1,
           let answerResult = await answerer.answer(
                question: question,
                scope: scope,
                detailLevel: detailLevel,
                fullContextMode: fullContextMode,
                now: now,
                timeZone: timeZone,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence,
                timeoutSeconds: answerTimeout
           ) {
            if let usage = answerResult.usage {
                await usageWriter.appendUsageEvent(usage)
            }
            return ResolvedAnswerPayload(payload: answerResult.payload, origin: .model)
        }

        if request.options.allowFallbacks {
            request.onProgress?("Answer model unavailable or timed out; returning evidence summary.")
            return ResolvedAnswerPayload(
                payload: fallbackAnswerBuilder.build(
                    question: question,
                    scopeLabel: scope.label,
                    detailLevel: detailLevel,
                    mem0Evidence: mem0Evidence,
                    bm25Evidence: bm25Evidence,
                    fullContextMode: fullContextMode
                ),
                origin: .fallback
            )
        }

        request.onProgress?("Answer model unavailable and fallback is disabled.")
        return ResolvedAnswerPayload(
            payload: MemoryQueryAnswerPayload(
                answer: "The query agent retrieved evidence but could not synthesize a final answer within the allotted budget, and fallback answering is disabled.",
                keyPoints: [],
                supportingEvents: [],
                insufficientEvidence: true
            ),
            origin: .failure
        )
    }

    private func overallDeadline(for options: MemoryQueryOptions) -> Date? {
        let requested = options.timeoutSeconds ?? runtimeConfig.timeoutSeconds
        guard let requested else {
            return nil
        }
        return Date().addingTimeInterval(max(1, requested))
    }

    private func remainingSeconds(until deadline: Date?) -> TimeInterval {
        guard let deadline else {
            return .greatestFiniteMagnitude
        }
        return max(0, deadline.timeIntervalSinceNow)
    }

    private func stageBudget(
        preferred: TimeInterval?,
        deadline: Date?,
        reserveSeconds: TimeInterval
    ) -> TimeInterval? {
        let remaining = remainingSeconds(until: deadline)
        if remaining == .greatestFiniteMagnitude {
            return preferred
        }

        let reserved = max(0, reserveSeconds)
        let protectedRemaining = max(0, remaining - reserved)
        if let preferred {
            if protectedRemaining >= 1 {
                return min(preferred, protectedRemaining)
            }
            return min(preferred, remaining)
        }
        if protectedRemaining >= 1 {
            return protectedRemaining
        }
        return remaining > 0 ? remaining : nil
    }

    private func executePlannedSteps(
        _ steps: [MemoryQueryPlanStep],
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        retrievalPlan: MemoryQueryRetrievalPlan,
        deadline: Date?,
        request: MemoryQueryRequest,
        profile: QueryIntentProfile
    ) async -> StepExecutionOutput {
        var aggregatedMem0: [MemoryEvidenceHit] = []
        var aggregatedBM25: [MemoryEvidenceHit] = []

        for phase in [MemoryQueryStepPhase.research, .evidence] {
            let phaseSteps = steps.filter { $0.phase == phase }
            guard !phaseSteps.isEmpty else { continue }
            guard remainingSeconds(until: deadline) > 0 else { break }

            let semanticQueries = selectedSemanticQueries(
                from: phaseSteps,
                profile: profile,
                detailLevel: detailLevel
            )
            let lexicalSteps = phaseSteps.filter { $0.sources.contains(.bm25Store) }
            let semanticBatchSuffix = semanticQueries.isEmpty ? "" : "; batching \(semanticQueries.count) semantic quer\(semanticQueries.count == 1 ? "y" : "ies")"
            request.onProgress?("Running \(phase.rawValue) retrieval with \(phaseSteps.count) step(s) in parallel\(semanticBatchSuffix)...")

            async let semanticHits: [MemoryEvidenceHit] = executeSemanticBatch(
                queries: semanticQueries,
                scope: scope,
                retrievalPlan: retrievalPlan,
                deadline: deadline,
                request: request,
                profile: profile
            )

            let lexicalHits = await withTaskGroup(of: [MemoryEvidenceHit].self) { group in
                for step in lexicalSteps {
                    group.addTask { [self] in
                        await executeLexicalStep(
                            step,
                            scope: scope,
                            detailLevel: detailLevel,
                            retrievalPlan: retrievalPlan,
                            deadline: deadline
                        )
                    }
                }

                var hits: [MemoryEvidenceHit] = []
                for await result in group {
                    hits.append(contentsOf: result)
                }
                return hits
            }

            aggregatedMem0.append(contentsOf: await semanticHits)
            aggregatedBM25.append(contentsOf: lexicalHits)
        }

        return StepExecutionOutput(mem0Hits: aggregatedMem0, bm25Hits: aggregatedBM25)
    }

    private func executeSemanticBatch(
        queries: [String],
        scope: MemoryQueryScope,
        retrievalPlan: MemoryQueryRetrievalPlan,
        deadline: Date?,
        request: MemoryQueryRequest,
        profile: QueryIntentProfile
    ) async -> [MemoryEvidenceHit] {
        guard !queries.isEmpty else {
            return []
        }

        let timeout = stageBudget(
            preferred: runtimeConfig.semanticSearchTimeoutSeconds,
            deadline: deadline,
            reserveSeconds: semanticReserveSeconds(request: request, profile: profile)
        )
        guard let timeout, timeout >= 1 else {
            return []
        }

        return await semanticRetriever.retrieve(
            queries: queries,
            scope: scope,
            limit: max(1, retrievalPlan.perPassSemanticLimit),
            timeoutSeconds: timeout
        )
    }

    private func executeLexicalStep(
        _ step: MemoryQueryPlanStep,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        retrievalPlan: MemoryQueryRetrievalPlan,
        deadline: Date?
    ) async -> [MemoryEvidenceHit] {
        guard remainingSeconds(until: deadline) > 0 else {
            return []
        }

        let effectiveStepLimit = resolvedStepLimit(
            step: step,
            detailLevel: detailLevel,
            retrievalPlan: retrievalPlan
        )
        let normalizedQuery = step.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        guard step.sources.contains(.bm25Store) else {
            return []
        }

        return await lexicalRetriever.retrieve(
            queries: [normalizedQuery],
            scope: scope,
            limit: effectiveStepLimit
        )
    }

    private func resolvedStepLimit(
        step: MemoryQueryPlanStep,
        detailLevel: MemoryQueryDetailLevel,
        retrievalPlan: MemoryQueryRetrievalPlan
    ) -> Int {
        let defaultLimit = detailLevel == .detailed ? 8 : 5
        let planBound = max(retrievalPlan.perPassLexicalLimit, retrievalPlan.perPassSemanticLimit, defaultLimit)
        if let maxResults = step.maxResults {
            return max(1, min(maxResults, planBound))
        }
        return defaultLimit
    }

    private func normalizedPlanSteps(
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

    private func stepKey(_ step: MemoryQueryPlanStep) -> String {
        let sources = step.sources.map(\.rawValue).sorted().joined(separator: ",")
        return "\(step.phase.rawValue)|\(sources)|\(step.query.lowercased())"
    }

    private func selectedSemanticQueries(
        from steps: [MemoryQueryPlanStep],
        profile: QueryIntentProfile,
        detailLevel: MemoryQueryDetailLevel
    ) -> [String] {
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

    private func plannerReserveSeconds(request: MemoryQueryRequest, profile: QueryIntentProfile) -> TimeInterval {
        let detailedBuffer: TimeInterval = profile.prefersDetailedAnswer ? 1.5 : 0
        if profile.prefersLexicalFirst {
            let base: TimeInterval = request.options.includesSemanticSearch && request.options.includesLexicalSearch ? 3 : 2
            return base + detailedBuffer
        }
        let base: TimeInterval = request.options.includesSemanticSearch || request.options.includesLexicalSearch ? 2 : 0
        return base + detailedBuffer
    }

    private func semanticReserveSeconds(request: MemoryQueryRequest, profile: QueryIntentProfile) -> TimeInterval {
        let detailedBuffer: TimeInterval = profile.prefersDetailedAnswer ? 0.75 : 0
        if profile.prefersLexicalFirst && request.options.includesLexicalSearch {
            return 1.5 + detailedBuffer
        }
        return (request.options.includesLexicalSearch ? 1 : 0.5) + detailedBuffer
    }

    private func formattedSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }

    private func resolvedScope(
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

    private func mergeMem0(
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

    private func mergeBM25(
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

    private func retrievalPlan(
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

    private func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func plannerQuestion(
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

    private func hasTranscriptCoverage(in evidence: [MemoryEvidenceHit]) -> Bool {
        evidence.filter { hit in
            hit.metadata["artifact_kind"] == ArtifactKind.audio.rawValue
                && hit.metadata["has_transcript"] == "true"
        }.count >= 2
    }

    private func shouldSwitchToFullContextMode(
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
}

private struct MemoryQueryRetrievalPlan {
    let semanticLimit: Int
    let lexicalLimit: Int
    let perPassSemanticLimit: Int
    let perPassLexicalLimit: Int
    let maxPlannerPasses: Int
    let targetEvidenceCount: Int
    let minPassesBeforeStop: Int
    let minEvidenceGainPerPass: Int
}

private struct StepExecutionOutput {
    var mem0Hits: [MemoryEvidenceHit] = []
    var bm25Hits: [MemoryEvidenceHit] = []
}

private struct ResolvedAnswerPayload {
    let payload: MemoryQueryAnswerPayload
    let origin: MemoryQueryAnswerOrigin
}
