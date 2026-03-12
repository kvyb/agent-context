import Foundation

final class MemoryQueryUseCase: @unchecked Sendable {
    private let semanticRetriever: SemanticMemoryRetrieving
    private let lexicalRetriever: LexicalMemoryRetrieving
    private let planner: MemoryQueryPlanning
    private let answerer: MemoryQueryAnswering
    private let usageWriter: UsageEventWriting
    private let scopeParser: MemoryQueryScopeParser

    init(
        semanticRetriever: SemanticMemoryRetrieving,
        lexicalRetriever: LexicalMemoryRetrieving,
        planner: MemoryQueryPlanning,
        answerer: MemoryQueryAnswering,
        usageWriter: UsageEventWriting,
        scopeParser: MemoryQueryScopeParser
    ) {
        self.semanticRetriever = semanticRetriever
        self.lexicalRetriever = lexicalRetriever
        self.planner = planner
        self.answerer = answerer
        self.usageWriter = usageWriter
        self.scopeParser = scopeParser
    }

    func execute(request: MemoryQueryRequest) async -> MemoryQueryResult {
        let trimmed = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MemoryQueryResult(
                query: request.question,
                answer: "Enter a question to query memory.",
                keyPoints: [],
                supportingEvents: [],
                insufficientEvidence: true,
                mem0SemanticCount: 0,
                bm25StoreCount: 0,
                scope: MemoryQueryScope(start: nil, end: nil, label: nil),
                generatedAt: Date()
            )
        }

        let fallbackScope = scopeParser.inferScope(for: trimmed)
        let plannerResult = await planner.plan(question: trimmed, now: Date())
        if let usage = plannerResult?.usage {
            await usageWriter.appendUsageEvent(usage)
        }

        let plannerQueries = plannerResult?.plan.queries ?? []
        let normalizedQueries = scopeParser.normalizedQueries(for: trimmed, plannerQueries: plannerQueries)
        let scope = plannerResult?.plan.scope ?? fallbackScope

        let mem0Evidence = await semanticRetriever.retrieve(
            queries: normalizedQueries,
            scope: scope,
            limit: 60
        )
        let bm25Evidence = await lexicalRetriever.retrieve(
            queries: normalizedQueries,
            scope: scope,
            limit: 40
        )

        guard !mem0Evidence.isEmpty || !bm25Evidence.isEmpty else {
            return MemoryQueryResult(
                query: trimmed,
                answer: "No matching memories found in Mem0/BM25 memory stores.",
                keyPoints: [],
                supportingEvents: [],
                insufficientEvidence: true,
                mem0SemanticCount: 0,
                bm25StoreCount: 0,
                scope: scope,
                generatedAt: Date()
            )
        }

        let payload: MemoryQueryAnswerPayload
        if let answerResult = await answerer.answer(
            question: trimmed,
            scopeLabel: scope.label,
            mem0Evidence: mem0Evidence,
            bm25Evidence: bm25Evidence
        ) {
            if let usage = answerResult.usage {
                await usageWriter.appendUsageEvent(usage)
            }
            payload = answerResult.payload
        } else {
            payload = fallbackPayload(
                question: trimmed,
                scopeLabel: scope.label,
                mem0Evidence: mem0Evidence,
                bm25Evidence: bm25Evidence
            )
        }

        return MemoryQueryResult(
            query: trimmed,
            answer: payload.answer,
            keyPoints: payload.keyPoints,
            supportingEvents: payload.supportingEvents,
            insufficientEvidence: payload.insufficientEvidence,
            mem0SemanticCount: mem0Evidence.count,
            bm25StoreCount: bm25Evidence.count,
            scope: scope,
            generatedAt: Date()
        )
    }

    private func fallbackPayload(
        question: String,
        scopeLabel: String?,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) -> MemoryQueryAnswerPayload {
        let scopedTitle: String
        if let scopeLabel = scopeLabel?.nilIfEmpty {
            scopedTitle = "Best matches (\(scopeLabel))"
        } else {
            scopedTitle = "Best matches"
        }

        let mem0Lines = mem0Evidence.prefix(8).map(formatEvidenceLine)
        let bm25Lines = bm25Evidence.prefix(8).map(formatEvidenceLine)
        let answer = ([scopedTitle, "Question: \(question)", "Mem0 semantic matches:"]
            + (mem0Lines.isEmpty ? ["- none"] : mem0Lines)
            + ["BM25 storage matches:"]
            + (bm25Lines.isEmpty ? ["- none"] : bm25Lines))
            .joined(separator: "\n")

        return MemoryQueryAnswerPayload(
            answer: answer,
            keyPoints: [],
            supportingEvents: [],
            insufficientEvidence: true
        )
    }

    private func formatEvidenceLine(_ hit: MemoryEvidenceHit) -> String {
        let iso = ISO8601DateFormatter()
        let timestamp = hit.occurredAt.map { iso.string(from: $0) } ?? "unknown-time"
        let app = hit.appName?.nilIfEmpty ?? "unknown-app"
        let project = hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty ?? ""
        let projectSuffix = project.isEmpty ? "" : " | project=\(project)"
        let sourceScore: Double
        switch hit.source {
        case .mem0Semantic:
            sourceScore = hit.semanticScore
        case .bm25Store:
            sourceScore = hit.lexicalScore
        }

        return "- [\(timestamp)] source=\(hit.source.rawValue) score=\(String(format: "%.2f", sourceScore)) app=\(app)\(projectSuffix) | \(hit.text)"
    }
}
