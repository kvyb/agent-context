import Foundation

struct MemoryQueryEvaluation: Sendable {
    let overallScore: Int
    let queryAlignmentScore: Int
    let retrievalRelevanceScore: Int
    let retrievalCoverageScore: Int
    let groundednessScore: Int
    let answerCompletenessScore: Int
    let summary: String
    let retrievalExplanation: String
    let groundednessExplanation: String
    let answerQualityExplanation: String
    let strengths: [String]
    let weaknesses: [String]
    let improvementActions: [String]
    let evidenceGaps: [String]
}

struct MemoryQueryEvaluationReport: Sendable {
    let trace: MemoryQueryExecutionTrace
    let evaluation: MemoryQueryEvaluation?
    let evaluationError: String?
    let latencySeconds: TimeInterval
}

struct MemoryQueryEvaluationResult: Sendable {
    let evaluation: MemoryQueryEvaluation
    let usage: LLMUsageEvent?
}
