import Foundation

final class MemoryQueryUseCase: @unchecked Sendable {
    private let planner: MemoryQueryPlanning
    private let answerer: MemoryQueryAnswering
    private let usageWriter: UsageEventWriting
    private let scopeParser: MemoryQueryScopeParser
    private let runtimeConfig: MemoryQueryRuntimeConfig
    private let calendar: Calendar
    private let heuristicPlanner: MemoryQueryHeuristicPlanner
    private let fallbackAnswerBuilder: MemoryQueryFallbackAnswerBuilder
    private let referenceDateProvider: @Sendable () -> Date
    private let budgetPolicy: MemoryQueryBudgetPolicy
    private let responseLimiter: MemoryQueryResponseLimiter
    private let resultFactory: MemoryQueryResultFactory
    private let retrievalSupport: MemoryQueryRetrievalSupport
    private let stepExecutor: MemoryQueryStepExecutor

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
        self.planner = planner
        self.answerer = answerer
        self.usageWriter = usageWriter
        self.scopeParser = scopeParser
        self.runtimeConfig = runtimeConfig
        self.calendar = calendar
        let heuristicPlanner = MemoryQueryHeuristicPlanner(scopeParser: scopeParser)
        let budgetPolicy = MemoryQueryBudgetPolicy(runtimeConfig: runtimeConfig)
        let retrievalSupport = MemoryQueryRetrievalSupport(
            heuristicPlanner: heuristicPlanner,
            scopeParser: scopeParser,
            calendar: calendar
        )
        self.heuristicPlanner = heuristicPlanner
        self.fallbackAnswerBuilder = MemoryQueryFallbackAnswerBuilder(calendar: calendar)
        self.referenceDateProvider = referenceDateProvider
        self.budgetPolicy = budgetPolicy
        self.responseLimiter = MemoryQueryResponseLimiter(maxApproximateResponseTokens: 2_000)
        self.resultFactory = MemoryQueryResultFactory()
        self.retrievalSupport = retrievalSupport
        self.stepExecutor = MemoryQueryStepExecutor(
            semanticRetriever: semanticRetriever,
            lexicalRetriever: lexicalRetriever,
            runtimeConfig: runtimeConfig,
            budgetPolicy: budgetPolicy,
            retrievalSupport: retrievalSupport
        )
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        await executeDetailed(request: request).result
    }

    func executeDetailed(request: MemoryQueryRequest) async -> MemoryQueryExecutionTrace {
        let trimmed = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return resultFactory.trace(
                result: resultFactory.emptyQueryResult(for: request.question),
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
        let deadline = budgetPolicy.overallDeadline(for: request.options)
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
            guard budgetPolicy.remainingSeconds(until: deadline) > 0 else {
                request.onProgress?("Query time budget exhausted; returning best partial result.")
                break
            }

            let planningQuestion = retrievalSupport.plannerQuestion(
                originalQuestion: trimmed,
                pass: pass,
                scope: scope,
                executedQueries: executedQueries,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            )

            let plannerTimeout = budgetPolicy.stageBudget(
                preferred: runtimeConfig.plannerTimeoutSeconds,
                deadline: deadline,
                reserveSeconds: budgetPolicy.plannerReserveSeconds(request: request, profile: queryProfile)
            )
            let plannerResult: MemoryQueryPlanResult?
            if let plannerTimeout, plannerTimeout < 1 {
                plannerResult = nil
            } else {
                let plannerBudgetLabel = plannerTimeout.map { budgetPolicy.formattedSeconds($0) } ?? "no stage cap"
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
                return resultFactory.trace(
                    result: resultFactory.failureResult(
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
                scope = retrievalSupport.resolveScope(
                    question: trimmed,
                    plannerScope: effectivePlannerResult?.plan.scope,
                    fallbackScope: fallbackScope
                )
            }

            let plannedSteps = retrievalSupport.normalizedPlanSteps(
                plan: effectivePlannerResult?.plan,
                originalQuestion: trimmed,
                request: request,
                profile: queryProfile
            )
            let freshSteps = plannedSteps.filter { step in
                let key = "\(step.phase.rawValue)|\(step.sources.map(\.rawValue).sorted().joined(separator: ","))|\(step.query.lowercased())"
                return executedQueryKeys.insert(key).inserted
            }
            freshSteps.forEach { executedQueries.append($0.query) }
            guard !freshSteps.isEmpty else { break }

            let effectivePlan = retrievalSupport.retrievalPlan(
                for: detailLevel,
                requestedMaxResults: request.options.maxResults,
                enabledSources: request.options.sources
            )
            let phaseResults = await stepExecutor.execute(
                steps: freshSteps,
                scope: scope,
                detailLevel: detailLevel,
                retrievalPlan: effectivePlan,
                deadline: deadline,
                request: request,
                profile: queryProfile
            )
            mem0Evidence = retrievalSupport.mergeSemanticHits(mem0Evidence, phaseResults.mem0Hits, limit: effectivePlan.semanticLimit)
            bm25Evidence = retrievalSupport.mergeLexicalHits(bm25Evidence, phaseResults.bm25Hits, limit: effectivePlan.lexicalLimit)

            let totalEvidenceCount = mem0Evidence.count + bm25Evidence.count
            let gained = totalEvidenceCount - previousEvidenceCount
            previousEvidenceCount = totalEvidenceCount

            if retrievalSupport.shouldSwitchToFullContextMode(
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
                fullContextMode = retrievalSupport.shouldSwitchToFullContextMode(
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
            return resultFactory.trace(
                result: resultFactory.noMatchesResult(for: trimmed, scope: scope),
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
        let payload = responseLimiter.bounded(answerOutput.payload)

        return resultFactory.trace(
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
        let answerTimeout = budgetPolicy.stageBudget(
            preferred: runtimeConfig.answerTimeoutSeconds,
            deadline: deadline,
            reserveSeconds: 0
        )
        if let answerTimeout {
            if answerTimeout >= 1 {
                request.onProgress?("Synthesizing answer (\(budgetPolicy.formattedSeconds(answerTimeout)) budget)...")
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

    private func hasTranscriptCoverage(in evidence: [MemoryEvidenceHit]) -> Bool {
        evidence.filter { hit in
            hit.metadata["artifact_kind"] == ArtifactKind.audio.rawValue
                && hit.metadata["has_transcript"] == "true"
        }.count >= 2
    }
}

private struct ResolvedAnswerPayload {
    let payload: MemoryQueryAnswerPayload
    let origin: MemoryQueryAnswerOrigin
}
