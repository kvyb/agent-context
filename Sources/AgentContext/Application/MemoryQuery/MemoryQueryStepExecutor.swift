import Foundation

struct MemoryQueryStepExecutor: Sendable {
    private let semanticRetriever: SemanticMemoryRetrieving
    private let lexicalRetriever: LexicalMemoryRetrieving
    private let runtimeConfig: MemoryQueryRuntimeConfig
    private let budgetPolicy: MemoryQueryBudgetPolicy
    private let retrievalSupport: MemoryQueryRetrievalSupport

    init(
        semanticRetriever: SemanticMemoryRetrieving,
        lexicalRetriever: LexicalMemoryRetrieving,
        runtimeConfig: MemoryQueryRuntimeConfig,
        budgetPolicy: MemoryQueryBudgetPolicy,
        retrievalSupport: MemoryQueryRetrievalSupport
    ) {
        self.semanticRetriever = semanticRetriever
        self.lexicalRetriever = lexicalRetriever
        self.runtimeConfig = runtimeConfig
        self.budgetPolicy = budgetPolicy
        self.retrievalSupport = retrievalSupport
    }

    func execute(
        steps: [MemoryQueryPlanStep],
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
            guard budgetPolicy.remainingSeconds(until: deadline) > 0 else { break }

            let semanticQueries = retrievalSupport.selectedSemanticQueries(
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
                            deadline: deadline,
                            request: request
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

        let timeout = budgetPolicy.stageBudget(
            preferred: runtimeConfig.semanticSearchTimeoutSeconds,
            deadline: deadline,
            reserveSeconds: budgetPolicy.semanticReserveSeconds(request: request, profile: profile)
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
        deadline: Date?,
        request: MemoryQueryRequest
    ) async -> [MemoryEvidenceHit] {
        guard budgetPolicy.remainingSeconds(until: deadline) > 0 else {
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
            limit: effectiveStepLimit,
            contextQuestion: request.question
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
}
