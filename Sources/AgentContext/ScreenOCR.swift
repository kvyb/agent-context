import Foundation

final class MemoryQueryService: @unchecked Sendable {
    private let settingsProvider: @Sendable () -> AppSettings
    private let apiKeyProvider: @Sendable () -> String?
    private let formatter: MemoryQueryFormatter
    private let useCase: MemoryQueryUseCase

    init(
        database: SQLiteStore,
        mem0Searcher: Mem0Searcher,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        apiKeyProvider: @escaping @Sendable () -> String?,
        openRouterConfig: OpenRouterRuntimeConfig
    ) {
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider

        let codec = MemoryQueryJSONCodec()
        let scopeParser = MemoryQueryScopeParser()
        let ranker = BM25Ranker()
        let usageWriter = SQLiteUsageEventWriter(database: database)

        let semanticRetriever = Mem0SemanticMemoryRetriever(
            searcher: mem0Searcher,
            settingsProvider: settingsProvider
        )
        let lexicalRetriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: ranker,
            scopeParser: scopeParser
        )
        let planner = OpenRouterMemoryQueryPlanner(
            openRouterConfig: openRouterConfig,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            codec: codec
        )
        let answerer = OpenRouterMemoryQueryAnswerer(
            openRouterConfig: openRouterConfig,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            codec: codec
        )

        useCase = MemoryQueryUseCase(
            semanticRetriever: semanticRetriever,
            lexicalRetriever: lexicalRetriever,
            planner: planner,
            answerer: answerer,
            usageWriter: usageWriter,
            scopeParser: scopeParser
        )
        formatter = MemoryQueryFormatter(codec: codec)
    }

    func answer(query: String) async -> String {
        await render(
            request: MemoryQueryRequest(
                question: query,
                outputFormat: .text
            )
        )
    }

    func render(request: MemoryQueryRequest) async -> String {
        let result = await execute(request: request)
        return formatter.render(result, as: request.outputFormat)
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        let query = request.question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard settingsProvider().mem0Enabled else {
            return unavailableResult(
                query: query,
                message: "Mem0 is disabled in settings."
            )
        }

        guard apiKeyProvider()?.nilIfEmpty != nil else {
            return unavailableResult(
                query: query,
                message: "OpenRouter API key is missing. Set it in Settings to query memory."
            )
        }

        return await useCase.execute(request: request)
    }

    private func unavailableResult(query: String, message: String) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: message,
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            bm25StoreCount: 0,
            scope: MemoryQueryScope(start: nil, end: nil, label: nil),
            generatedAt: Date()
        )
    }
}
