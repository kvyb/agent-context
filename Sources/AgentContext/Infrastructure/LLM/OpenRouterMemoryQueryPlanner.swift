import Foundation

final class OpenRouterMemoryQueryPlanner: MemoryQueryPlanning, @unchecked Sendable {
    private let openRouterConfig: OpenRouterRuntimeConfig
    private let settingsProvider: @Sendable () -> AppSettings
    private let apiKeyProvider: @Sendable () -> String?
    private let codec: MemoryQueryJSONCodec

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
    }

    func plan(
        question: String,
        now: Date,
        detailLevel: MemoryQueryDetailLevel,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryPlanResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }
        let effectiveTimeout = timeoutSeconds.map { min(openRouterConfig.timeoutSeconds, $0) } ?? openRouterConfig.timeoutSeconds
        guard effectiveTimeout > 0 else {
            return nil
        }

        let settings = settingsProvider()
        let client = OpenRouterClient(
            config: OpenRouterRuntimeConfig(
                endpoint: openRouterConfig.endpoint,
                model: openRouterConfig.model,
                queryAgentModel: openRouterConfig.queryAgentModel,
                evaluationModel: openRouterConfig.evaluationModel,
                reasoningEffort: openRouterConfig.reasoningEffort,
                queryAgentReasoningEffort: openRouterConfig.queryAgentReasoningEffort,
                timeoutSeconds: effectiveTimeout
            ),
            settings: settings
        )

        do {
            let response = try client.planMemoryQuery(
                question: question,
                now: now,
                detailLevel: detailLevel,
                timeZone: timeZone,
                apiKey: apiKey
            )
            guard let plan = codec.parsePlan(from: response.text) else {
                return nil
            }
            return MemoryQueryPlanResult(plan: plan, usage: response.usage)
        } catch {
            fputs("[agent-context] Planner error: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
