import Foundation

struct MemoryQueryResultFactory: Sendable {
    func emptyQueryResult(for query: String) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: "Enter a question to query memory.",
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            scope: MemoryQueryScope(start: nil, end: nil, label: nil),
            generatedAt: Date()
        )
    }

    func noMatchesResult(for query: String, scope: MemoryQueryScope) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: "No matching memories found in the enabled memory sources.",
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            scope: scope,
            generatedAt: Date()
        )
    }

    func failureResult(for query: String, scope: MemoryQueryScope, message: String) -> MemoryQueryResult {
        MemoryQueryResult(
            query: query,
            answer: message,
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true,
            mem0SemanticCount: 0,
            scope: scope,
            generatedAt: Date()
        )
    }

    func trace(
        result: MemoryQueryResult,
        mem0Evidence: [MemoryEvidenceHit],
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        answerOrigin: MemoryQueryAnswerOrigin
    ) -> MemoryQueryExecutionTrace {
        MemoryQueryExecutionTrace(
            result: result,
            mem0Evidence: mem0Evidence,
            detailLevel: detailLevel,
            fullContextMode: fullContextMode,
            answerOrigin: answerOrigin
        )
    }
}
