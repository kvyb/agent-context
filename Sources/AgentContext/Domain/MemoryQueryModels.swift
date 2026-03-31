import Foundation

enum MemoryQueryOutputFormat: String, Sendable {
    case text
    case json
}

enum MemoryQueryDetailLevel: String, Sendable {
    case concise
    case detailed
}

struct MemoryQueryOptions: Sendable {
    let scopeOverride: MemoryQueryScope?
    let maxResults: Int?
    let timeoutSeconds: TimeInterval?
    let allowFallbacks: Bool

    static let `default` = MemoryQueryOptions(
        scopeOverride: nil,
        maxResults: nil,
        timeoutSeconds: nil,
        allowFallbacks: true
    )
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

enum MemoryEvidenceSource: String, Codable, Sendable, Hashable {
    case mem0Semantic = "mem0_semantic"
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

struct MemoryQueryNormalizationResult: Sendable {
    let queries: [String]
    let usage: LLMUsageEvent?
}

struct MemoryQueryResult: Sendable {
    let query: String
    let answer: String
    let keyPoints: [String]
    let supportingEvents: [String]
    let insufficientEvidence: Bool
    let mem0SemanticCount: Int
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

protocol MemoryQueryAnswering: Sendable {
    func answer(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryAnswerResult?
}

protocol MemoryQueryNormalizing: Sendable {
    func normalize(
        question: String,
        scope: MemoryQueryScope,
        now: Date,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryNormalizationResult?
}

protocol UsageEventWriting: Sendable {
    func appendUsageEvent(_ event: LLMUsageEvent) async
}
