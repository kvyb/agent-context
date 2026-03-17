import Foundation

final class Mem0SemanticMemoryRetriever: SemanticMemoryRetrieving, @unchecked Sendable {
    private let searcher: Mem0Searcher
    private let settingsProvider: @Sendable () -> AppSettings

    init(
        searcher: Mem0Searcher,
        settingsProvider: @escaping @Sendable () -> AppSettings
    ) {
        self.searcher = searcher
        self.settingsProvider = settingsProvider
    }

    func retrieve(
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int,
        timeoutSeconds: TimeInterval?
    ) async -> [MemoryEvidenceHit] {
        let settings = settingsProvider()
        var merged: [String: MemoryEvidenceHit] = [:]

        let hits = searcher.searchBatch(
            queries: Array(queries.prefix(10)),
            start: scope.start,
            end: scope.end,
            limit: max(1, limit),
            timeoutSeconds: timeoutSeconds,
            settings: settings
        )

        let total = max(1, hits.count)
        let maxRawScore = max(hits.compactMap(\.score).max() ?? 0, 0.000_1)

        for (index, hit) in hits.enumerated() {
            let text = hit.memory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let timeKey = hit.occurredAt.map { Int($0.timeIntervalSince1970 / 30) } ?? 0
            let key = "mem0|\(timeKey)|\(text.prefix(160).lowercased())"
            let semanticScore: Double
            if let rawScore = hit.score, rawScore > 0 {
                semanticScore = min(1, max(0, rawScore / maxRawScore))
            } else {
                semanticScore = 1.0 - (Double(index) / Double(total))
            }

            if let existing = merged[key], existing.semanticScore >= semanticScore {
                continue
            }

            let normalizedMetadata = hit.metadata.reduce(into: [String: String]()) { acc, pair in
                if let value = pair.value.nilIfEmpty {
                    acc[pair.key] = value
                }
            }

            merged[key] = MemoryEvidenceHit(
                id: key,
                source: .mem0Semantic,
                text: text,
                appName: hit.appName?.nilIfEmpty,
                project: hit.project?.nilIfEmpty,
                occurredAt: hit.occurredAt,
                metadata: normalizedMetadata,
                semanticScore: semanticScore,
                lexicalScore: 0,
                hybridScore: semanticScore
            )
        }

        return merged.values
            .sorted {
                if abs($0.semanticScore - $1.semanticScore) > 0.0001 {
                    return $0.semanticScore > $1.semanticScore
                }
                return ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }
}
