import Foundation

final class OpenRouterMemoryQueryNormalizer: MemoryQueryNormalizing, @unchecked Sendable {
    private let openRouterConfig: OpenRouterRuntimeConfig
    private let settingsProvider: @Sendable () -> AppSettings
    private let apiKeyProvider: @Sendable () -> String?

    init(
        openRouterConfig: OpenRouterRuntimeConfig,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.openRouterConfig = openRouterConfig
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
    }

    func normalize(
        question: String,
        scope: MemoryQueryScope,
        now: Date,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryNormalizationResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }

        let effectiveTimeout: TimeInterval? = {
            switch (timeoutSeconds, openRouterConfig.timeoutSeconds) {
            case let (lhs?, rhs?):
                return min(lhs, rhs)
            case let (lhs?, nil):
                return lhs
            case let (nil, rhs?):
                return rhs
            case (nil, nil):
                return nil
            }
        }()

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
            settings: settingsProvider()
        )

        do {
            let response = try client.normalizeMemoryQuery(
                question: question,
                scope: scope,
                now: now,
                timeZone: timeZone,
                apiKey: apiKey
            )
            let queries = parseQueries(from: response.text)
            guard !queries.isEmpty else {
                return nil
            }
            return MemoryQueryNormalizationResult(queries: queries, usage: response.usage)
        } catch {
            fputs("[agent-context] Query normalizer error: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private func parseQueries(from text: String) -> [String] {
        guard
            let data = text.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let object = raw as? [String: Any],
            let queries = object["search_queries"] as? [String]
        else {
            return []
        }

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
