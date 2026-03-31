import Foundation

final class MemoryQueryService: @unchecked Sendable {
    private let formatter: MemoryQueryFormatter
    private let useCase: MemoryQueryUseCase

    init(
        database: SQLiteStore,
        mem0Searcher: Mem0Searcher,
        settingsProvider: @escaping @Sendable () -> AppSettings,
        apiKeyProvider: @escaping @Sendable () -> String?,
        openRouterConfig: OpenRouterRuntimeConfig,
        runtimeConfig: MemoryQueryRuntimeConfig
    ) {
        let codec = MemoryQueryJSONCodec()
        let scopeParser = MemoryQueryScopeParser()
        let usageWriter = SQLiteUsageEventWriter(database: database)

        let semanticRetriever = Mem0SemanticMemoryRetriever(
            searcher: mem0Searcher,
            settingsProvider: settingsProvider
        )
        let normalizer = OpenRouterMemoryQueryNormalizer(
            openRouterConfig: openRouterConfig,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider
        )
        let answerer = OpenRouterMemoryQueryAnswerer(
            openRouterConfig: openRouterConfig,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            codec: codec
        )

        useCase = MemoryQueryUseCase(
            semanticRetriever: semanticRetriever,
            normalizer: normalizer,
            answerer: answerer,
            usageWriter: usageWriter,
            scopeParser: scopeParser,
            runtimeConfig: runtimeConfig
        )
        formatter = MemoryQueryFormatter(codec: codec)
    }

    func render(request: MemoryQueryRequest) async -> String {
        let result = await execute(request: request)
        return formatter.render(result, as: request.outputFormat)
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        await useCase.execute(request: request)
    }

    func executeDetailed(request: MemoryQueryRequest) async -> MemoryQueryExecutionTrace {
        await useCase.executeDetailed(request: request)
    }
}
