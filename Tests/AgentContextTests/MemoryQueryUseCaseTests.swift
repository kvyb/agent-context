import XCTest
@testable import AgentContext

final class MemoryQueryUseCaseTests: XCTestCase {
    func testUseCaseUsesDirectMem0PathForMem0OnlyRequests() async {
        let semantic = FakeSemanticRetriever(hits: [
            sampleHit(id: "s1", text: "Reviewed ManyChat PR 556", score: 0.9)
        ])
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
            normalizer: FakeNormalizer(result: nil),
            answerer: answerer,
            usageWriter: usageWriter,
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "ManyChat status this week", outputFormat: .text)
        )

        XCTAssertEqual(result.answer, "Done and pending summarized.")
        XCTAssertEqual(result.mem0SemanticCount, 1)
        XCTAssertEqual(result.scope.label, "this week")
        let semanticQueries = await semantic.lastQueries()
        XCTAssertEqual(semanticQueries, ["ManyChat status this week"])
        let answererFullContextMode = await answerer.lastFullContextMode()
        XCTAssertEqual(answererFullContextMode, true)
        let answererTimeout = await answerer.lastTimeoutSeconds()
        XCTAssertEqual(answererTimeout ?? 0, 3, accuracy: 0.25)
        let usageCount = await usageWriter.eventCount()
        XCTAssertEqual(usageCount, 1)
    }

    func testUseCaseFallsBackWhenAnswererFails() async {
        let semantic = FakeSemanticRetriever(hits: [
            sampleHit(id: "s1", text: "Worked on AI service", score: 0.8)
        ])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            normalizer: FakeNormalizer(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "what happened?", outputFormat: .text)
        )

        XCTAssertTrue(result.answer.contains("Worked on AI service"))
        XCTAssertEqual(result.supportingEvents.count, 1)
        XCTAssertTrue(result.insufficientEvidence)
    }

    func testUseCaseCanRunWithoutAnswerStageCaps() async {
        let answerer = FakeAnswerer(
            result: MemoryQueryAnswerResult(
                payload: MemoryQueryAnswerPayload(
                    answer: "Answered without stage caps.",
                    keyPoints: [],
                    supportingEvents: [],
                    insufficientEvidence: false
                ),
                usage: nil
            )
        )
        let useCase = MemoryQueryUseCase(
            semanticRetriever: FakeSemanticRetriever(hits: [
                sampleHit(id: "s1", text: "ManyChat work item", score: 0.9)
            ]),
            normalizer: FakeNormalizer(result: nil),
            answerer: answerer,
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: MemoryQueryRuntimeConfig(
                timeoutSeconds: nil,
                answerTimeoutSeconds: nil,
                semanticSearchTimeoutSeconds: 5
            )
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "ManyChat status", outputFormat: .text)
        )

        XCTAssertEqual(result.answer, "Answered without stage caps.")
        let answererTimeout = await answerer.lastTimeoutSeconds()
        XCTAssertNil(answererTimeout)
    }

    func testUseCasePrefersNormalizedQueriesForMem0Retrieval() async {
        let semantic = FakeSemanticRetriever(hits: [
            sampleHit(id: "s1", text: "Zoom meeting recap", score: 0.9)
        ])
        let usageWriter = FakeUsageWriter()
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            normalizer: FakeNormalizer(
                result: MemoryQueryNormalizationResult(
                    queries: ["Zoom calls discussed on 2026-03-30", "meeting transcript 2026-03-30 feedback Wednesday"],
                    usage: sampleUsage(id: "normalize-1")
                )
            ),
            answerer: FakeAnswerer(result: nil),
            usageWriter: usageWriter,
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(question: "what did i discuss on calls yesterday?", outputFormat: .text)
        )

        let semanticQueries = await semantic.lastQueries()
        XCTAssertEqual(
            semanticQueries,
            [
                "Zoom calls discussed on 2026-03-30",
                "meeting transcript 2026-03-30 feedback Wednesday",
                "what did i discuss on calls yesterday?"
            ]
        )
        let usageCount = await usageWriter.eventCount()
        XCTAssertEqual(usageCount, 1)
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

    private func sampleRuntimeConfig() -> MemoryQueryRuntimeConfig {
        MemoryQueryRuntimeConfig(
            timeoutSeconds: 12,
            answerTimeoutSeconds: 3,
            semanticSearchTimeoutSeconds: 5
        )
    }

    private func sampleHit(id: String, text: String, score: Double) -> MemoryEvidenceHit {
        MemoryEvidenceHit(
            id: id,
            source: .mem0Semantic,
            text: text,
            appName: "App",
            project: "Project",
            occurredAt: Date(),
            metadata: [:],
            semanticScore: score,
            lexicalScore: 0,
            hybridScore: score
        )
    }
}

private final class FakeSemanticRetriever: SemanticMemoryRetrieving, @unchecked Sendable {
    private let hits: [MemoryEvidenceHit]
    private let recorder = TimeoutRecorder()
    private let queryRecorder = QueryRecorder()

    init(hits: [MemoryEvidenceHit]) {
        self.hits = hits
    }

    func retrieve(
        queries: [String],
        scope: MemoryQueryScope,
        limit: Int,
        timeoutSeconds: TimeInterval?
    ) async -> [MemoryEvidenceHit] {
        await recorder.record(timeoutSeconds)
        await queryRecorder.record(queries)
        return Array(hits.prefix(limit))
    }

    func lastQueries() async -> [String] {
        await queryRecorder.lastValue()
    }
}

private final class FakeAnswerer: MemoryQueryAnswering, @unchecked Sendable {
    private let result: MemoryQueryAnswerResult?
    private let recorder = TimeoutRecorder()
    private let fullContextRecorder = BoolRecorder()

    init(result: MemoryQueryAnswerResult?) {
        self.result = result
    }

    func answer(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        fullContextMode: Bool,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryAnswerResult? {
        await recorder.record(timeoutSeconds)
        await fullContextRecorder.record(fullContextMode)
        return result
    }

    func lastTimeoutSeconds() async -> TimeInterval? {
        await recorder.lastValue()
    }

    func lastFullContextMode() async -> Bool? {
        await fullContextRecorder.lastValue()
    }
}

private struct FakeNormalizer: MemoryQueryNormalizing {
    let result: MemoryQueryNormalizationResult?

    func normalize(
        question: String,
        scope: MemoryQueryScope,
        now: Date,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval?
    ) async -> MemoryQueryNormalizationResult? {
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

private actor TimeoutRecorder {
    private var values: [TimeInterval?] = []

    func record(_ value: TimeInterval?) {
        values.append(value)
    }

    func lastValue() -> TimeInterval? {
        values.last ?? nil
    }
}

private actor QueryRecorder {
    private var values: [[String]] = []

    func record(_ value: [String]) {
        values.append(value)
    }

    func lastValue() -> [String] {
        values.last ?? []
    }
}

private actor BoolRecorder {
    private var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }

    func lastValue() -> Bool? {
        values.last
    }
}
