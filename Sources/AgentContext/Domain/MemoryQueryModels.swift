import Foundation

enum MemoryQueryOutputFormat: String, Sendable {
    case text
    case json
}

enum MemoryQueryDetailLevel: String, Sendable {
    case concise
    case detailed
}

enum MemoryQueryStepPhase: String, Sendable, Codable {
    case research
    case evidence
}

struct MemoryQueryOptions: Sendable {
    let sources: Set<MemoryEvidenceSource>
    let scopeOverride: MemoryQueryScope?
    let maxResults: Int?
    let timeoutSeconds: TimeInterval?
    let allowFallbacks: Bool

    static let `default` = MemoryQueryOptions(
        sources: Set(MemoryEvidenceSource.allCases),
        scopeOverride: nil,
        maxResults: nil,
        timeoutSeconds: nil,
        allowFallbacks: true
    )

    var includesSemanticSearch: Bool {
        sources.contains(.mem0Semantic)
    }

    var includesLexicalSearch: Bool {
        sources.contains(.bm25Store)
    }
}

struct MemoryQueryRequest: Sendable {
    let question: String
    let outputFormat: MemoryQueryOutputFormat
    let options: MemoryQueryOptions
    let onProgress: (@Sendable (String) -> Void)?

    init(
        question: String,
        outputFormat: MemoryQueryOutputFormat,
        options: MemoryQueryOptions = .default,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) {
        self.question = question
        self.outputFormat = outputFormat
        self.options = options
        self.onProgress = onProgress
    }
}

struct MemoryQueryScope: Sendable, Codable {
    let start: Date?
    let end: Date?
    let label: String?
}

enum MemoryEvidenceSource: String, Codable, Sendable, CaseIterable, Hashable {
    case mem0Semantic = "mem0_semantic"
    case bm25Store = "bm25_store"

    init?(cliValue raw: String) {
        switch raw.lowercased() {
        case "mem0", "semantic", "mem0_semantic":
            self = .mem0Semantic
        case "bm25", "lexical", "bm25_store":
            self = .bm25Store
        default:
            return nil
        }
    }
}

struct MemoryEvidenceHit: Sendable {
    let id: String
    let source: MemoryEvidenceSource
    let text: String
    let appName: String?
    let project: String?
    let occurredAt: Date?
    let metadata: [String: String]
    let semanticScore: Double
    let lexicalScore: Double
    let hybridScore: Double
}

struct MemoryQueryPlanStep: Sendable {
    let query: String
    let sources: Set<MemoryEvidenceSource>
    let phase: MemoryQueryStepPhase
    let maxResults: Int?

    init(
        query: String,
        sources: Set<MemoryEvidenceSource> = Set(MemoryEvidenceSource.allCases),
        phase: MemoryQueryStepPhase = .evidence,
        maxResults: Int? = nil
    ) {
        self.query = query
        self.sources = sources.isEmpty ? Set(MemoryEvidenceSource.allCases) : sources
        self.phase = phase
        self.maxResults = maxResults
    }
}

struct MemoryQueryPlan: Sendable {
    let steps: [MemoryQueryPlanStep]
    let scope: MemoryQueryScope
    let detailLevel: MemoryQueryDetailLevel

    init(
        queries: [String],
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel = .concise
    ) {
        self.steps = queries.compactMap { query in
            guard let normalized = query.nilIfEmpty else { return nil }
            return MemoryQueryPlanStep(query: normalized)
        }
        self.scope = scope
        self.detailLevel = detailLevel
    }

    init(
        steps: [MemoryQueryPlanStep],
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel = .concise
    ) {
        self.steps = steps.compactMap { step in
            guard let normalized = step.query.nilIfEmpty else { return nil }
            return MemoryQueryPlanStep(
                query: normalized,
                sources: step.sources,
                phase: step.phase,
                maxResults: step.maxResults
            )
        }
        self.scope = scope
        self.detailLevel = detailLevel
    }

    var queries: [String] {
        steps.map(\.query)
    }
}

struct MemoryQueryPlanResult: Sendable {
    let plan: MemoryQueryPlan
    let usage: LLMUsageEvent?
}

struct MemoryQueryAnswerPayload: Sendable {
    let answer: String
    let keyPoints: [String]
    let supportingEvents: [String]
    let insufficientEvidence: Bool
}

struct MemoryQueryAnswerResult: Sendable {
    let payload: MemoryQueryAnswerPayload
    let usage: LLMUsageEvent?
}

struct MemoryQueryResult: Sendable {
    let query: String
    let answer: String
    let keyPoints: [String]
    let supportingEvents: [String]
    let insufficientEvidence: Bool
    let mem0SemanticCount: Int
    let bm25StoreCount: Int
    let scope: MemoryQueryScope
    let generatedAt: Date
}

enum MemoryQueryAnswerOrigin: String, Sendable {
    case model
    case fallback
    case failure
}

struct MemoryQueryExecutionTrace: Sendable {
    let result: MemoryQueryResult
    let mem0Evidence: [MemoryEvidenceHit]
    let bm25Evidence: [MemoryEvidenceHit]
    let detailLevel: MemoryQueryDetailLevel
    let fullContextMode: Bool
    let answerOrigin: MemoryQueryAnswerOrigin
}

protocol SemanticMemoryRetrieving: Sendable {
    func retrieve(
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int,
        timeoutSeconds: TimeInterval?
    ) async -> [MemoryEvidenceHit]
}

protocol LexicalMemoryRetrieving: Sendable {
    func retrieve(
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int,
        contextQuestion: String?
    ) async -> [MemoryEvidenceHit]
}

extension LexicalMemoryRetrieving {
    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        await retrieve(
            queries: queries,
            scope: scope,
            limit: limit,
            contextQuestion: nil
        )
    }
}

protocol MemoryQueryPlanning: Sendable {
    func plan(
        question: String,
        now: Date,
        detailLevel: MemoryQueryDetailLevel,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryPlanResult?
}

protocol MemoryQueryAnswering: Sendable {
    func answer(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit],
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryAnswerResult?
}

protocol UsageEventWriting: Sendable {
    func appendUsageEvent(_ event: LLMUsageEvent) async
}
