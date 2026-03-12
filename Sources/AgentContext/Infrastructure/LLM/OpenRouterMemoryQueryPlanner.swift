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

    func plan(question: String, now: Date) async -> MemoryQueryPlanResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }

        let settings = settingsProvider()
        let client = OpenRouterClient(config: openRouterConfig, settings: settings)

        do {
            let response = try client.planMemoryQuery(question: question, now: now, apiKey: apiKey)
            guard let plan = codec.parsePlan(from: response.text) else {
                return nil
            }
            return MemoryQueryPlanResult(plan: plan, usage: response.usage)
        } catch {
            return nil
        }
    }
}
