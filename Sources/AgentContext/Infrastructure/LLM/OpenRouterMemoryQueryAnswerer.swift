import Foundation

final class OpenRouterMemoryQueryAnswerer: MemoryQueryAnswering, @unchecked Sendable {
    private let openRouterConfig: OpenRouterRuntimeConfig
    private let settingsProvider: @Sendable () -> AppSettings
    private let apiKeyProvider: @Sendable () -> String?
    private let codec: MemoryQueryJSONCodec
    private let evidenceFormatter: MemoryQueryEvidenceFormatter
    private let questionAnalyzer: MemoryQueryQuestionAnalyzer

    init(
        openRouterConfig: OpenRouterRuntimeConfig,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        apiKeyProvider: @escaping @Sendable () -> String?,
        codec: MemoryQueryJSONCodec
    ) {
        self.openRouterConfig = openRouterConfig
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.codec = codec
        self.evidenceFormatter = MemoryQueryEvidenceFormatter()
        self.questionAnalyzer = MemoryQueryQuestionAnalyzer(scopeParser: MemoryQueryScopeParser())
    }

    func answer(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit],
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryAnswerResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }
        let effectiveTimeout = timeoutSeconds.map { min(openRouterConfig.timeoutSeconds, $0) } ?? openRouterConfig.timeoutSeconds
        guard effectiveTimeout > 0 else {
            return nil
        }

        let settings = settingsProvider()
        let analysis = questionAnalyzer.analyze(question: question)
        let client = OpenRouterClient(
            config: OpenRouterRuntimeConfig(
                endpoint: openRouterConfig.endpoint,
                model: openRouterConfig.model,
                reasoningEffort: openRouterConfig.reasoningEffort,
                timeoutSeconds: effectiveTimeout
            ),
            settings: settings
        )

        let evidenceLimit = analysis.prefersLexicalFirst
            ? (fullContextMode ? 96 : (detailLevel == .detailed ? 72 : 36))
            : (fullContextMode ? 180 : (detailLevel == .detailed ? 120 : 36))
        let orderedMem0 = orderedEvidence(mem0Evidence, detailLevel: detailLevel, analysis: analysis)
        let orderedBM25 = orderedEvidence(bm25Evidence, detailLevel: detailLevel, analysis: analysis)
        let mem0Lines = orderedMem0.prefix(evidenceLimit).map(evidenceFormatter.formatLine)
        let bm25Lines = orderedBM25.prefix(evidenceLimit).map(evidenceFormatter.formatLine)
        let retryEvidenceLimit = analysis.prefersLexicalFirst ? min(evidenceLimit, 40) : min(evidenceLimit, 28)
        let retryMem0Lines = orderedMem0.prefix(retryEvidenceLimit).map(evidenceFormatter.formatLine)
        let retryBM25Lines = orderedBM25.prefix(retryEvidenceLimit).map(evidenceFormatter.formatLine)

        do {
            let response = try client.answerMemoryQuery(
                question: question,
                scope: scope,
                detailLevel: detailLevel,
                fullContextMode: fullContextMode,
                now: now,
                timeZone: timeZone,
                mem0EvidenceLines: mem0Lines,
                bm25EvidenceLines: bm25Lines,
                apiKey: apiKey
            )

            if let payload = codec.parseAnswer(from: response.text) {
                return MemoryQueryAnswerResult(payload: payload, usage: response.usage)
            }

            fputs("[agent-context] Answerer parse failure; retrying with simplified prompt.\n", stderr)
            let retryResponse = try client.answerMemoryQuery(
                question: question,
                scope: scope,
                detailLevel: detailLevel,
                fullContextMode: fullContextMode,
                now: now,
                timeZone: timeZone,
                mem0EvidenceLines: retryMem0Lines,
                bm25EvidenceLines: retryBM25Lines,
                promptMode: .retry,
                apiKey: apiKey
            )

            if let payload = codec.parseAnswer(from: retryResponse.text) {
                return MemoryQueryAnswerResult(payload: payload, usage: retryResponse.usage)
            }

            let retryExcerpt = retryResponse.text.prefix(320).replacingOccurrences(of: "\n", with: " ")
            fputs("[agent-context] Answerer retry parse failure: \(retryExcerpt)\n", stderr)
            return nil
        } catch {
            fputs("[agent-context] Answerer error: \(error.localizedDescription); retrying with simplified prompt.\n", stderr)

            do {
                let retryResponse = try client.answerMemoryQuery(
                    question: question,
                    scope: scope,
                    detailLevel: detailLevel,
                    fullContextMode: fullContextMode,
                    now: now,
                    timeZone: timeZone,
                    mem0EvidenceLines: retryMem0Lines,
                    bm25EvidenceLines: retryBM25Lines,
                    promptMode: .retry,
                    apiKey: apiKey
                )

                if let payload = codec.parseAnswer(from: retryResponse.text) {
                    return MemoryQueryAnswerResult(payload: payload, usage: retryResponse.usage)
                }

                let retryExcerpt = retryResponse.text.prefix(320).replacingOccurrences(of: "\n", with: " ")
                fputs("[agent-context] Answerer retry parse failure: \(retryExcerpt)\n", stderr)
                return nil
            } catch {
                fputs("[agent-context] Answerer retry error: \(error.localizedDescription)\n", stderr)
                return nil
            }
        }
    }

    private func orderedEvidence(
        _ evidence: [MemoryEvidenceHit],
        detailLevel: MemoryQueryDetailLevel,
        analysis: MemoryQueryQuestionAnalysis
    ) -> [MemoryEvidenceHit] {
        if analysis.prefersLexicalFirst {
            let transcriptHits = evidence
                .filter(isTranscriptChunk)
                .sorted(by: transcriptEvidenceSort)
            let supportingHits = evidence
                .filter { !isTranscriptChunk($0) }
                .sorted(by: supportingEvidenceSort)
            let supportingLimit = analysis.seeksEvaluation ? 10 : 16
            return transcriptHits + Array(supportingHits.prefix(supportingLimit))
        }

        return evidence.sorted {
            let left = $0.occurredAt ?? .distantPast
            let right = $1.occurredAt ?? .distantPast
            if detailLevel == .detailed {
                return left < right
            }
            return left > right
        }
    }

    private func isTranscriptChunk(_ hit: MemoryEvidenceHit) -> Bool {
        let retrievalUnit = hit.metadata["retrieval_unit"]
        return retrievalUnit == "transcript_chunk" || retrievalUnit == "transcript_unit"
    }

    private func transcriptEvidenceSort(_ lhs: MemoryEvidenceHit, _ rhs: MemoryEvidenceHit) -> Bool {
        if abs(lhs.hybridScore - rhs.hybridScore) > 0.0001 {
            return lhs.hybridScore > rhs.hybridScore
        }
        let lhsExchange = lhs.metadata["speaker_exchange"] == "true"
        let rhsExchange = rhs.metadata["speaker_exchange"] == "true"
        if lhsExchange != rhsExchange {
            return lhsExchange && !rhsExchange
        }
        return (lhs.occurredAt ?? .distantPast) < (rhs.occurredAt ?? .distantPast)
    }

    private func supportingEvidenceSort(_ lhs: MemoryEvidenceHit, _ rhs: MemoryEvidenceHit) -> Bool {
        if abs(lhs.hybridScore - rhs.hybridScore) > 0.0001 {
            return lhs.hybridScore > rhs.hybridScore
        }
        return (lhs.occurredAt ?? .distantPast) > (rhs.occurredAt ?? .distantPast)
    }
}
