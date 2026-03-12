import Foundation

enum MemoryQueryOutputFormat: String, Sendable {
    case text
    case json
}

struct MemoryQueryRequest: Sendable {
    let question: String
    let outputFormat: MemoryQueryOutputFormat
}

struct MemoryQueryScope: Sendable, Codable {
    let start: Date?
    let end: Date?
    let label: String?
}

enum MemoryEvidenceSource: String, Codable, Sendable {
    case mem0Semantic = "mem0_semantic"
    case bm25Store = "bm25_store"
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

struct MemoryQueryPlan: Sendable {
    let queries: [String]
    let scope: MemoryQueryScope
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

protocol SemanticMemoryRetrieving: Sendable {
    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit]
}

protocol LexicalMemoryRetrieving: Sendable {
    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit]
}

protocol MemoryQueryPlanning: Sendable {
    func plan(question: String, now: Date) async -> MemoryQueryPlanResult?
}

protocol MemoryQueryAnswering: Sendable {
    func answer(
        question: String,
        scopeLabel: String?,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) async -> MemoryQueryAnswerResult?
}

protocol UsageEventWriting: Sendable {
    func appendUsageEvent(_ event: LLMUsageEvent) async
}
