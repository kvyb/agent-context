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
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) async -> MemoryQueryAnswerResult? {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            return nil
        }

        let settings = settingsProvider()
        let client = OpenRouterClient(config: openRouterConfig, settings: settings)

        let evidenceLimit = detailLevel == .detailed ? 120 : 36
        let orderedMem0 = orderedEvidence(mem0Evidence, detailLevel: detailLevel)
        let orderedBM25 = orderedEvidence(bm25Evidence, detailLevel: detailLevel)
        let mem0Lines = orderedMem0.prefix(evidenceLimit).map(formatEvidenceLine)
        let bm25Lines = orderedBM25.prefix(evidenceLimit).map(formatEvidenceLine)

        do {
            let response = try client.answerMemoryQuery(
                question: question,
                scope: scope,
                detailLevel: detailLevel,
                now: now,
                timeZone: timeZone,
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

    private func orderedEvidence(
        _ evidence: [MemoryEvidenceHit],
        detailLevel: MemoryQueryDetailLevel
    ) -> [MemoryEvidenceHit] {
        evidence.sorted {
            let left = $0.occurredAt ?? .distantPast
            let right = $1.occurredAt ?? .distantPast
            if detailLevel == .detailed {
                return left < right
            }
            return left > right
        }
    }
}
