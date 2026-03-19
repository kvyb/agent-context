import Foundation

final class Mem0SemanticMemoryRetriever: SemanticMemoryRetrieving, @unchecked Sendable {
    private let searcher: Mem0Searcher
    private let settingsProvider: @Sendable () -> AppSettings
    private let resultReranker: Mem0ResultReranker

    init(
        searcher: Mem0Searcher,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        resultReranker: Mem0ResultReranker = Mem0ResultReranker()
    ) {
        self.searcher = searcher
        self.settingsProvider = settingsProvider
        self.resultReranker = resultReranker
    }

    func retrieve(
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int,
        timeoutSeconds: TimeInterval?
    ) async -> [MemoryEvidenceHit] {
        let settings = settingsProvider()
        let hits = searcher.searchBatch(
            queries: Array(queries.prefix(10)),
            start: scope.start,
            end: scope.end,
            limit: max(1, limit),
            timeoutSeconds: timeoutSeconds,
            settings: settings
        )

        return resultReranker.rerank(
            hits: hits,
            queries: queries,
            scope: scope,
            limit: limit
        )
    }
}
