import Foundation

final class OpenRouterMemoryQueryAnswerer: MemoryQueryAnswering, @unchecked Sendable {
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

    func answer(
        question: String,
        scopeLabel: String?,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) async -> MemoryQueryAnswerResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }

        let settings = settingsProvider()
        let client = OpenRouterClient(config: openRouterConfig, settings: settings)

        let mem0Lines = mem0Evidence.prefix(24).map(formatEvidenceLine)
        let bm25Lines = bm25Evidence.prefix(24).map(formatEvidenceLine)

        do {
            let response = try client.answerMemoryQuery(
                question: question,
                scopeLabel: scopeLabel,
                mem0EvidenceLines: mem0Lines,
                bm25EvidenceLines: bm25Lines,
                apiKey: apiKey
            )

            guard let payload = codec.parseAnswer(from: response.text) else {
                return nil
            }
            return MemoryQueryAnswerResult(payload: payload, usage: response.usage)
        } catch {
            return nil
        }
    }

    private func formatEvidenceLine(_ hit: MemoryEvidenceHit) -> String {
        let iso = ISO8601DateFormatter()
        let timestamp = hit.occurredAt.map { iso.string(from: $0) } ?? "unknown-time"
        let app = hit.appName?.nilIfEmpty ?? "unknown-app"
        let project = hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty ?? ""
        let projectSuffix = project.isEmpty ? "" : " | project=\(project)"
        let score: Double = (hit.source == .mem0Semantic) ? hit.semanticScore : hit.lexicalScore
        return "[\(timestamp)] source=\(hit.source.rawValue) score=\(String(format: "%.2f", score)) app=\(app)\(projectSuffix) | memory=\(hit.text)"
    }
}
