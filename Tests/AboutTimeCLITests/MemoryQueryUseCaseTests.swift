import XCTest
@testable import AboutTimeCLI

final class MemoryQueryUseCaseTests: XCTestCase {
    func testUseCaseUsesDualRetrieversAndAnswerer() async {
        let semantic = FakeSemanticRetriever(hits: [
            MemoryEvidenceHit(
                id: "s1",
                source: .mem0Semantic,
                text: "Reviewed ManyChat PR 556",
                appName: "GitHub",
                project: "ManyChat",
                occurredAt: Date(),
                metadata: [:],
                semanticScore: 0.9,
                lexicalScore: 0,
                hybridScore: 0.9
            )
        ])
        let lexical = FakeLexicalRetriever(hits: [
            MemoryEvidenceHit(
                id: "b1",
                source: .bm25Store,
                text: "Pending: finalize intent detection PRD",
                appName: "Notion",
                project: "ManyChat",
                occurredAt: Date(),
                metadata: [:],
                semanticScore: 0,
                lexicalScore: 0.7,
                hybridScore: 0.72
            )
        ])
        let planner = FakePlanner(
            result: MemoryQueryPlanResult(
                plan: MemoryQueryPlan(
                    queries: ["manychat status"],
                    scope: MemoryQueryScope(start: nil, end: nil, label: "this week")
                ),
                usage: sampleUsage(id: "plan-1")
            )
        )
        let answerer = FakeAnswerer(
            result: MemoryQueryAnswerResult(
                payload: MemoryQueryAnswerPayload(
                    answer: "Done and pending summarized.",
                    keyPoints: ["Done item"],
                    supportingEvents: ["Event item"],
                    insufficientEvidence: false
                ),
                usage: sampleUsage(id: "answer-1")
            )
        )
        let usageWriter = FakeUsageWriter()
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: answerer,
            usageWriter: usageWriter,
            scopeParser: MemoryQueryScopeParser()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "ManyChat status this week", outputFormat: .text)
        )

        XCTAssertEqual(result.answer, "Done and pending summarized.")
        XCTAssertEqual(result.mem0SemanticCount, 1)
        XCTAssertEqual(result.bm25StoreCount, 1)
        XCTAssertEqual(result.scope.label, "this week")
        let usageCount = await usageWriter.eventCount()
        XCTAssertEqual(usageCount, 2)
    }

    func testUseCaseFallsBackWhenAnswererFails() async {
        let semantic = FakeSemanticRetriever(hits: [
            MemoryEvidenceHit(
                id: "s1",
                source: .mem0Semantic,
                text: "Worked on AI service",
                appName: "Codex",
                project: "ManyChat",
                occurredAt: Date(),
                metadata: [:],
                semanticScore: 0.8,
                lexicalScore: 0,
                hybridScore: 0.8
            )
        ])
        let lexical = FakeLexicalRetriever(hits: [])
        let planner = FakePlanner(result: nil)
        let answerer = FakeAnswerer(result: nil)
        let usageWriter = FakeUsageWriter()
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: answerer,
            usageWriter: usageWriter,
            scopeParser: MemoryQueryScopeParser()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "what happened?", outputFormat: .text)
        )

        XCTAssertTrue(result.answer.contains("Mem0 semantic matches:"))
        XCTAssertTrue(result.insufficientEvidence)
    }

    private func sampleUsage(id: String) -> LLMUsageEvent {
        LLMUsageEvent(
            id: id,
            kind: "test",
            createdAt: Date(),
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            audioTokens: 0,
            estimatedCostUSD: 0.001
        )
    }
}

private final class FakeSemanticRetriever: SemanticMemoryRetrieving, @unchecked Sendable {
    private let hits: [MemoryEvidenceHit]

    init(hits: [MemoryEvidenceHit]) {
        self.hits = hits
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        Array(hits.prefix(limit))
    }
}

private final class FakeLexicalRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let hits: [MemoryEvidenceHit]

    init(hits: [MemoryEvidenceHit]) {
        self.hits = hits
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        Array(hits.prefix(limit))
    }
}

private final class FakePlanner: MemoryQueryPlanning, @unchecked Sendable {
    private let result: MemoryQueryPlanResult?

    init(result: MemoryQueryPlanResult?) {
        self.result = result
    }

    func plan(question: String, now: Date) async -> MemoryQueryPlanResult? {
        result
    }
}

private final class FakeAnswerer: MemoryQueryAnswering, @unchecked Sendable {
    private let result: MemoryQueryAnswerResult?

    init(result: MemoryQueryAnswerResult?) {
        self.result = result
    }

    func answer(
        question: String,
        scopeLabel: String?,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit]
    ) async -> MemoryQueryAnswerResult? {
        result
    }
}

private actor FakeUsageWriter: UsageEventWriting {
    private(set) var events: [LLMUsageEvent] = []

    func appendUsageEvent(_ event: LLMUsageEvent) async {
        events.append(event)
    }

    func eventCount() -> Int {
        events.count
    }
}
