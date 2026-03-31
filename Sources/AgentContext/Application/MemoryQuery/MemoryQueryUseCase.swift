import Foundation

final class MemoryQueryUseCase: @unchecked Sendable {
    private let semanticRetriever: SemanticMemoryRetrieving
    private let normalizer: MemoryQueryNormalizing
    private let answerer: MemoryQueryAnswering
    private let usageWriter: UsageEventWriting
    private let scopeParser: MemoryQueryScopeParser
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer
    private let runtimeConfig: MemoryQueryRuntimeConfig
    private let calendar: Calendar
    private let fallbackAnswerBuilder: MemoryQueryFallbackAnswerBuilder
    private let referenceDateProvider: @Sendable () -> Date
    private let budgetPolicy: MemoryQueryBudgetPolicy
    private let responseLimiter: MemoryQueryResponseLimiter
    private let resultFactory: MemoryQueryResultFactory

    init(
        semanticRetriever: SemanticMemoryRetrieving,
        normalizer: MemoryQueryNormalizing,
        answerer: MemoryQueryAnswering,
        usageWriter: UsageEventWriting,
        scopeParser: MemoryQueryScopeParser,
        runtimeConfig: MemoryQueryRuntimeConfig,
        calendar: Calendar = .autoupdatingCurrent,
        referenceDateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.semanticRetriever = semanticRetriever
        self.normalizer = normalizer
        self.answerer = answerer
        self.usageWriter = usageWriter
        self.scopeParser = scopeParser
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: scopeParser)
        self.runtimeConfig = runtimeConfig
        self.calendar = calendar
        let budgetPolicy = MemoryQueryBudgetPolicy(runtimeConfig: runtimeConfig)
        self.fallbackAnswerBuilder = MemoryQueryFallbackAnswerBuilder(calendar: calendar)
        self.referenceDateProvider = referenceDateProvider
        self.budgetPolicy = budgetPolicy
        self.responseLimiter = MemoryQueryResponseLimiter(maxApproximateResponseTokens: 10_000)
        self.resultFactory = MemoryQueryResultFactory()
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
                detailLevel: .concise,
                fullContextMode: false,
                answerOrigin: .failure
            )
        }

        let now = referenceDateProvider()
        let timeZone = calendar.timeZone
        let fallbackScope = request.options.scopeOverride ?? scopeParser.inferScope(for: trimmed, referenceDate: now)
        let deadline = budgetPolicy.overallDeadline(for: request.options)

        return await executeDirectMem0(
            question: trimmed,
            scope: fallbackScope,
            analysis: questionAnalyzer.analyze(question: trimmed),
            now: now,
            timeZone: timeZone,
            deadline: deadline,
            request: request
        )
    }

    private func resolveAnswerPayload(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
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

    private func executeDirectMem0(
        question: String,
        scope: MemoryQueryScope,
        analysis: MemoryQueryQuestionAnalysis,
        now: Date,
        timeZone: TimeZone,
        deadline: Date?,
        request: MemoryQueryRequest
    ) async -> MemoryQueryExecutionTrace {
        let prefersScopedCoverage = (scope.start != nil || scope.end != nil)
            && (analysis.seeksWorkSummary || analysis.seeksCallConversation)
        let detailLevel: MemoryQueryDetailLevel = (analysis.prefersDetailedAnswer || prefersScopedCoverage) ? .detailed : .concise
        let semanticLimit = request.options.maxResults ?? (detailLevel == .detailed ? 24 : 12)
        let normalizationTimeout = budgetPolicy.stageBudget(
            preferred: 8,
            deadline: deadline,
            reserveSeconds: 0
        )
        request.onProgress?("Normalizing search query...")
        let retrievalQueries = await normalizedQueries(
            question: question,
            scope: scope,
            now: now,
            timeZone: timeZone,
            timeoutSeconds: normalizationTimeout
        )
        request.onProgress?("Running direct Mem0 retrieval...")

        let mem0Evidence = await semanticRetriever.retrieve(
            queries: retrievalQueries,
            scope: scope,
            limit: semanticLimit,
            timeoutSeconds: request.options.timeoutSeconds
        )

        guard !mem0Evidence.isEmpty else {
            return resultFactory.trace(
                result: resultFactory.noMatchesResult(for: question, scope: scope),
                mem0Evidence: [],
                detailLevel: detailLevel,
                fullContextMode: false,
                answerOrigin: .failure
            )
        }

        let answerOutput = await resolveAnswerPayload(
            question: question,
            scope: scope,
            detailLevel: detailLevel,
            now: now,
            timeZone: timeZone,
            mem0Evidence: mem0Evidence,
            fullContextMode: true,
            deadline: deadline,
            request: request
        )
        let payload = responseLimiter.bounded(answerOutput.payload)

        return resultFactory.trace(
            result: MemoryQueryResult(
                query: question,
                answer: payload.answer,
                keyPoints: payload.keyPoints,
                supportingEvents: payload.supportingEvents,
                insufficientEvidence: payload.insufficientEvidence,
                mem0SemanticCount: mem0Evidence.count,
                scope: scope,
                generatedAt: now
            ),
            mem0Evidence: mem0Evidence,
            detailLevel: detailLevel,
            fullContextMode: true,
            answerOrigin: answerOutput.origin
        )
    }

    private func normalizedQueries(
        question: String,
        scope: MemoryQueryScope,
        now: Date,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> [String] {
        var queries: [String] = []

        if let normalized = await normalizer.normalize(
            question: question,
            scope: scope,
            now: now,
            timeZone: timeZone,
            timeoutSeconds: timeoutSeconds
        ) {
            if let usage = normalized.usage {
                await usageWriter.appendUsageEvent(usage)
            }
            queries.append(contentsOf: normalized.queries)
        }

        queries.append(question)

        var seen = Set<String>()
        return queries.compactMap { raw in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            guard let normalized else { return nil }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
    }
}

private struct ResolvedAnswerPayload {
    let payload: MemoryQueryAnswerPayload
    let origin: MemoryQueryAnswerOrigin
}
