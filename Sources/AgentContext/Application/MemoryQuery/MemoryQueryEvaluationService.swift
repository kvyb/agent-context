import Foundation

final class MemoryQueryEvaluationService: @unchecked Sendable {
    private let queryService: MemoryQueryService
    private let evaluator: OpenRouterMemoryQueryEvaluator
    private let formatter: MemoryQueryEvaluationFormatter
    private let usageWriter: UsageEventWriting

    init(
        queryService: MemoryQueryService,
        evaluator: OpenRouterMemoryQueryEvaluator,
        usageWriter: UsageEventWriting
    ) {
        self.queryService = queryService
        self.evaluator = evaluator
        self.formatter = MemoryQueryEvaluationFormatter()
        self.usageWriter = usageWriter
    }

    func render(request: MemoryQueryRequest) async -> String {
        let report = await evaluate(request: request)
        return formatter.render(report, as: request.outputFormat)
    }

    func evaluate(request: MemoryQueryRequest) async -> MemoryQueryEvaluationReport {
        let startedAt = Date()
        let trace = await queryService.executeDetailed(request: request)
        let latencySeconds = Date().timeIntervalSince(startedAt)

        guard let evaluationResult = await evaluator.evaluate(trace: trace, latencySeconds: latencySeconds) else {
            return MemoryQueryEvaluationReport(
                trace: trace,
                evaluation: nil,
                evaluationError: "Evaluator model unavailable or returned an invalid score payload.",
                latencySeconds: latencySeconds
            )
        }

        if let usage = evaluationResult.usage {
            await usageWriter.appendUsageEvent(usage)
        }

        return MemoryQueryEvaluationReport(
            trace: trace,
            evaluation: evaluationResult.evaluation,
            evaluationError: nil,
            latencySeconds: latencySeconds
        )
    }
}
