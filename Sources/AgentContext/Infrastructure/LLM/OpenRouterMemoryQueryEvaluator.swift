import Foundation

final class OpenRouterMemoryQueryEvaluator: @unchecked Sendable {
    private let openRouterConfig: OpenRouterRuntimeConfig
    private let settingsProvider: @Sendable () -> AppSettings
    private let apiKeyProvider: @Sendable () -> String?
    private let codec: MemoryQueryEvaluationCodec
    private let evidenceFormatter: MemoryQueryEvidenceFormatter

    init(
        openRouterConfig: OpenRouterRuntimeConfig,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        apiKeyProvider: @escaping @Sendable () -> String?,
        codec: MemoryQueryEvaluationCodec
    ) {
        self.openRouterConfig = openRouterConfig
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.codec = codec
        self.evidenceFormatter = MemoryQueryEvidenceFormatter()
    }

    func evaluate(
        trace: MemoryQueryExecutionTrace,
        latencySeconds: TimeInterval
    ) async -> MemoryQueryEvaluationResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }

        let settings = settingsProvider()
        let client = OpenRouterClient(
            config: openRouterConfig,
            settings: settings
        )

        let mem0EvidenceLines = orderedEvidence(trace.mem0Evidence).map(evidenceFormatter.formatLine)
        let primaryInput = EvaluationInput(
            answer: trace.result.answer,
            keyPoints: trace.result.keyPoints,
            supportingEvents: trace.result.supportingEvents,
            mem0EvidenceLines: Array(mem0EvidenceLines.prefix(trace.traceRequiresBroaderEvidencePreview ? 20 : 12))
        )
        let retryInput = EvaluationInput(
            answer: String(trace.result.answer.prefix(2_400)),
            keyPoints: Array(trace.result.keyPoints.prefix(6)),
            supportingEvents: Array(trace.result.supportingEvents.prefix(6)),
            mem0EvidenceLines: Array(mem0EvidenceLines.prefix(10))
        )

        do {
            let attempts = [primaryInput, retryInput]
            for (index, input) in attempts.enumerated() {
                let response = try client.evaluateMemoryQuery(
                    question: trace.result.query,
                    answer: input.answer,
                    answerOrigin: trace.answerOrigin,
                    latencySeconds: latencySeconds,
                    scope: trace.result.scope,
                    detailLevel: trace.detailLevel,
                    mem0EvidenceLines: input.mem0EvidenceLines,
                    keyPoints: input.keyPoints,
                    supportingEvents: input.supportingEvents,
                    apiKey: apiKey
                )

                if let evaluation = codec.parse(from: response.text) {
                    return MemoryQueryEvaluationResult(evaluation: evaluation, usage: response.usage)
                }

                let preview = response.text.prefix(320).replacingOccurrences(of: "\n", with: " ")
                if index + 1 < attempts.count {
                    fputs("[agent-context] Evaluator parse failure; retrying with a smaller evidence pack: \(preview)\n", stderr)
                } else {
                    fputs("[agent-context] Evaluator parse failure: \(preview)\n", stderr)
                }
            }
            return nil
        } catch {
            fputs("[agent-context] Evaluator error: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private func orderedEvidence(_ hits: [MemoryEvidenceHit]) -> [MemoryEvidenceHit] {
        hits.sorted {
            if abs($0.hybridScore - $1.hybridScore) > 0.0001 {
                return $0.hybridScore > $1.hybridScore
            }
            return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
        }
    }
}

private extension MemoryQueryExecutionTrace {
    var traceRequiresBroaderEvidencePreview: Bool {
        detailLevel == .detailed || result.keyPoints.count >= 10 || fullContextMode
    }
}

private struct EvaluationInput {
    let answer: String
    let keyPoints: [String]
    let supportingEvents: [String]
    let mem0EvidenceLines: [String]
}
