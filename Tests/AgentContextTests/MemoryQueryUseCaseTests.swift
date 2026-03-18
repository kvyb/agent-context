import XCTest
@testable import AgentContext

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
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "ManyChat status this week", outputFormat: .text)
        )

        XCTAssertEqual(result.answer, "Done and pending summarized.")
        XCTAssertEqual(result.mem0SemanticCount, 1)
        XCTAssertEqual(result.bm25StoreCount, 1)
        XCTAssertEqual(result.scope.label, "this week")
        let usageCount = await usageWriter.eventCount()
        XCTAssertEqual(usageCount, 3)
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
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(question: "what happened?", outputFormat: .text)
        )

        XCTAssertTrue(result.answer.contains("I found"))
        XCTAssertTrue(result.answer.contains("Worked on AI service"))
        XCTAssertEqual(result.keyPoints, ["Worked on AI service"])
        XCTAssertEqual(result.supportingEvents.count, 1)
        XCTAssertTrue(result.insufficientEvidence)
    }

    func testUseCaseHonorsSourceFilterAndMaxResults() async {
        let semantic = FakeSemanticRetriever(hits: [
            sampleHit(id: "s1", source: .mem0Semantic, text: "Semantic one", score: 0.9),
            sampleHit(id: "s2", source: .mem0Semantic, text: "Semantic two", score: 0.8)
        ])
        let lexical = FakeLexicalRetriever(hits: [
            sampleHit(id: "b1", source: .bm25Store, text: "Lexical one", score: 0.7),
            sampleHit(id: "b2", source: .bm25Store, text: "Lexical two", score: 0.6),
            sampleHit(id: "b3", source: .bm25Store, text: "Lexical three", score: 0.5)
        ])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: FakePlanner(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(
                question: "status",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.bm25Store],
                    scopeOverride: nil,
                    maxResults: 2,
                    timeoutSeconds: 8
                )
            )
        )

        XCTAssertEqual(result.mem0SemanticCount, 0)
        XCTAssertEqual(result.bm25StoreCount, 2)
        XCTAssertTrue(result.answer.contains("Lexical one"))
        XCTAssertEqual(result.supportingEvents.count, 2)
        let semanticTimeoutCount = await semantic.timeoutCount()
        XCTAssertEqual(semanticTimeoutCount, 0)
    }

    func testFallbackTranscriptAnswerMentionsMissingVerbatimTranscript() async {
        let semantic = FakeSemanticRetriever(hits: [])
        let lexical = FakeLexicalRetriever(hits: [
            sampleHit(
                id: "b1",
                source: .bm25Store,
                text: "Participated in a Zoom technical interview with Mikhail Baranov and used Metaview AI Notetaker for documentation.",
                score: 0.95
            )
        ])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: FakePlanner(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(
                question: "find the zoom interview transcript",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.bm25Store],
                    scopeOverride: nil,
                    maxResults: 3,
                    timeoutSeconds: 10
                )
            )
        )

        XCTAssertTrue(result.answer.contains("did not find a verbatim transcript"))
        XCTAssertTrue(result.answer.contains("Zoom technical interview"))
    }

    func testUseCasePassesStageTimeoutsToCollaborators() async {
        let semantic = FakeSemanticRetriever(hits: [])
        let lexical = FakeLexicalRetriever(hits: [])
        let planner = FakePlanner(result: nil)
        let answerer = FakeAnswerer(result: nil)
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: answerer,
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: MemoryQueryRuntimeConfig(
                timeoutSeconds: 12,
                plannerTimeoutSeconds: 4,
                answerTimeoutSeconds: 3,
                semanticSearchTimeoutSeconds: 5
            )
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(
                question: "recent status",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.mem0Semantic],
                    scopeOverride: nil,
                    maxResults: 1,
                    timeoutSeconds: 10
                )
            )
        )

        let plannerTimeout = await planner.lastTimeoutSeconds()
        let semanticTimeout = await semantic.lastTimeoutSeconds()
        let answererTimeout = await answerer.lastTimeoutSeconds()

        XCTAssertEqual(plannerTimeout ?? 0, 4, accuracy: 0.25)
        XCTAssertEqual(semanticTimeout ?? 0, 5, accuracy: 0.25)
        XCTAssertNil(answererTimeout)
    }

    func testUseCaseFallsBackToHeuristicPlannerQueries() async {
        let semantic = FakeSemanticRetriever(hits: [])
        let lexical = FakeLexicalRetriever(hits: [])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: FakePlanner(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(
                question: "find the zoom interview transcript",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.mem0Semantic],
                    scopeOverride: nil,
                    maxResults: 3,
                    timeoutSeconds: 10
                )
            )
        )

        let recordedQueries = await semantic.allQueries().flatMap { $0 }
        XCTAssertTrue(recordedQueries.contains("zoom interview"))
        XCTAssertGreaterThan(Set(recordedQueries).count, 1)
    }

    func testTranscriptStyleQueriesPreferLexicalFirst() async {
        let semantic = FakeSemanticRetriever(hits: [sampleHit(id: "s1", source: .mem0Semantic, text: "semantic", score: 0.9)])
        let lexical = FakeLexicalRetriever(hits: [sampleHit(id: "b1", source: .bm25Store, text: "lexical", score: 0.9)])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: FakePlanner(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(
                question: "find the zoom interview transcript",
                outputFormat: .text,
                options: MemoryQueryOptions.default
            )
        )

        let lexicalCallCount = await lexical.callCount()
        XCTAssertGreaterThan(lexicalCallCount, 0)
    }

    func testUseCaseExecutesStructuredStepsPerSource() async {
        let semantic = FakeSemanticRetriever(hits: [sampleHit(id: "s1", source: .mem0Semantic, text: "semantic", score: 0.9)])
        let lexical = FakeLexicalRetriever(hits: [sampleHit(id: "b1", source: .bm25Store, text: "lexical", score: 0.9)])
        let planner = FakePlanner(
            result: MemoryQueryPlanResult(
                plan: MemoryQueryPlan(
                    steps: [
                        MemoryQueryPlanStep(query: "zoom interview", sources: [.bm25Store], phase: .research, maxResults: 4),
                        MemoryQueryPlanStep(query: "mikhail baranov", sources: [.mem0Semantic], phase: .evidence, maxResults: 3)
                    ],
                    scope: MemoryQueryScope(start: nil, end: nil, label: nil)
                ),
                usage: nil
            )
        )
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(question: "find the interview", outputFormat: .text)
        )

        let semanticQueries = await semantic.lastQueries()
        let lexicalQueries = await lexical.lastQueries()
        XCTAssertEqual(semanticQueries, ["mikhail baranov"])
        XCTAssertEqual(lexicalQueries, ["zoom interview"])
    }

    func testUseCaseBatchesSemanticQueriesWithinPhase() async {
        let semantic = FakeSemanticRetriever(hits: [sampleHit(id: "s1", source: .mem0Semantic, text: "semantic", score: 0.9)])
        let lexical = FakeLexicalRetriever(hits: [])
        let planner = FakePlanner(
            result: MemoryQueryPlanResult(
                plan: MemoryQueryPlan(
                    steps: [
                        MemoryQueryPlanStep(query: "manychat", sources: [.mem0Semantic], phase: .evidence, maxResults: 4),
                        MemoryQueryPlanStep(query: "manychat tasks", sources: [.mem0Semantic], phase: .evidence, maxResults: 4),
                        MemoryQueryPlanStep(query: "manychat blockers", sources: [.mem0Semantic], phase: .evidence, maxResults: 4)
                    ],
                    scope: MemoryQueryScope(start: nil, end: nil, label: nil),
                    detailLevel: .detailed
                ),
                usage: nil
            )
        )
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(),
            runtimeConfig: sampleRuntimeConfig()
        )

        _ = await useCase.execute(
            request: MemoryQueryRequest(question: "summarize manychat work", outputFormat: .text)
        )

        let semanticCallCount = await semantic.timeoutCount()
        let semanticQueries = await semantic.lastQueries()
        XCTAssertEqual(semanticCallCount, 1)
        XCTAssertEqual(semanticQueries, ["manychat", "manychat tasks", "manychat blockers"])
    }

    func testRelativeScopeIsNotBroadenedByPlanner() async {
        let referenceNow = date(year: 2026, month: 3, day: 17, hour: 12)
        let semantic = FakeSemanticRetriever(hits: [])
        let lexical = FakeLexicalRetriever(hits: [
            sampleHit(id: "b1", source: .bm25Store, text: "Transcript summary: candidate discussed retrieval metrics", score: 0.9)
        ])
        let planner = FakePlanner(
            result: MemoryQueryPlanResult(
                plan: MemoryQueryPlan(
                    queries: ["candidate interview"],
                    scope: MemoryQueryScope(
                        start: Date(timeIntervalSince1970: 0),
                        end: Date(timeIntervalSince1970: 172_800),
                        label: "last 48 hours"
                    ),
                    detailLevel: .detailed
                ),
                usage: nil
            )
        )
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: planner,
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(calendar: fixedCalendar),
            runtimeConfig: sampleRuntimeConfig(),
            calendar: fixedCalendar,
            referenceDateProvider: { referenceNow }
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(
                question: "How well did the candidate from the zoom interview last night do?",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.bm25Store],
                    scopeOverride: nil,
                    maxResults: 3,
                    timeoutSeconds: 10
                )
            )
        )

        XCTAssertEqual(result.scope.label, "last night")
        XCTAssertEqual(result.scope.start, date(year: 2026, month: 3, day: 16, hour: 18))
        XCTAssertEqual(result.scope.end, date(year: 2026, month: 3, day: 17, hour: 6))
    }

    func testInterviewEvaluationFallbackBuildsStructuredAssessmentFromTranscriptEvidence() async {
        let referenceNow = date(year: 2026, month: 3, day: 17, hour: 12)
        let semantic = FakeSemanticRetriever(hits: [])
        let lexical = FakeLexicalRetriever(hits: [
            MemoryEvidenceHit(
                id: "audio-1",
                source: .bm25Store,
                text: "Transcript summary: S1: We built a GraphRAG workflow over company reports and used a vector database when normal retrieval missed business relationships. S1: We evaluate retrieval quality with NDCG and an LLM judge.",
                appName: "zoom.us",
                project: "AI Core Team",
                occurredAt: date(year: 2026, month: 3, day: 16, hour: 21),
                metadata: [
                    "artifact_kind": ArtifactKind.audio.rawValue,
                    "has_transcript": "true"
                ],
                semanticScore: 0,
                lexicalScore: 0.95,
                hybridScore: 1.02
            ),
            MemoryEvidenceHit(
                id: "audio-2",
                source: .bm25Store,
                text: "Transcript summary: S1: For production we monitor response distributions in Grafana and use A/B testing before broader rollout. S1: When requirements are fuzzy I clarify trade-offs with stakeholders and peers.",
                appName: "Codex",
                project: "AI Core Team",
                occurredAt: date(year: 2026, month: 3, day: 16, hour: 21),
                metadata: [
                    "artifact_kind": ArtifactKind.audio.rawValue,
                    "has_transcript": "true"
                ],
                semanticScore: 0,
                lexicalScore: 0.92,
                hybridScore: 0.99
            ),
            MemoryEvidenceHit(
                id: "audio-3",
                source: .bm25Store,
                text: "Transcript summary: S1: I was not sure who owned one part of the legacy pipeline, so I would validate that in a follow-up before changing it.",
                appName: "Orion",
                project: "AI Core Team",
                occurredAt: date(year: 2026, month: 3, day: 16, hour: 22),
                metadata: [
                    "artifact_kind": ArtifactKind.audio.rawValue,
                    "has_transcript": "true"
                ],
                semanticScore: 0,
                lexicalScore: 0.88,
                hybridScore: 0.94
            ),
            MemoryEvidenceHit(
                id: "meta-1",
                source: .bm25Store,
                text: "Telegram reminder to analyze the interview transcript later in OpenTulpa.",
                appName: "Telegram",
                project: "OpenTulpa",
                occurredAt: date(year: 2026, month: 3, day: 16, hour: 23),
                metadata: [:],
                semanticScore: 0,
                lexicalScore: 0.4,
                hybridScore: 0.45
            )
        ])
        let useCase = MemoryQueryUseCase(
            semanticRetriever: semantic,
            lexicalRetriever: lexical,
            planner: FakePlanner(result: nil),
            answerer: FakeAnswerer(result: nil),
            usageWriter: FakeUsageWriter(),
            scopeParser: MemoryQueryScopeParser(calendar: fixedCalendar),
            runtimeConfig: sampleRuntimeConfig(),
            calendar: fixedCalendar,
            referenceDateProvider: { referenceNow }
        )

        let result = await useCase.execute(
            request: MemoryQueryRequest(
                question: "How well did the candidate from the zoom interview on 2026-03-16 match an intermediate level? What questions were answered, and what does the transcript suggest about strengths, weaknesses, and fit?",
                outputFormat: .text,
                options: MemoryQueryOptions(
                    sources: [.bm25Store],
                    scopeOverride: nil,
                    maxResults: 6,
                    timeoutSeconds: 10
                )
            )
        )

        XCTAssertTrue(result.answer.contains("Questions Answered:"))
        XCTAssertTrue(result.answer.contains("Strengths:"))
        XCTAssertTrue(result.answer.contains("Weaknesses:"))
        XCTAssertTrue(result.answer.contains("Fit:"))
        XCTAssertFalse(result.insufficientEvidence)
        XCTAssertTrue(
            result.answer.localizedCaseInsensitiveContains("evaluation")
                || result.answer.localizedCaseInsensitiveContains("ranking metrics")
                || result.answer.localizedCaseInsensitiveContains("ndcg")
                || result.keyPoints.contains(where: {
                    $0.localizedCaseInsensitiveContains("evaluation")
                        || $0.localizedCaseInsensitiveContains("ndcg")
                })
        )
        XCTAssertFalse(result.answer.contains("Telegram reminder"))
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
            plannerTimeoutSeconds: 4,
            answerTimeoutSeconds: 3,
            semanticSearchTimeoutSeconds: 5
        )
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sampleHit(id: String, source: MemoryEvidenceSource, text: String, score: Double) -> MemoryEvidenceHit {
        MemoryEvidenceHit(
            id: id,
            source: source,
            text: text,
            appName: "App",
            project: "Project",
            occurredAt: Date(),
            metadata: [:],
            semanticScore: source == .mem0Semantic ? score : 0,
            lexicalScore: source == .bm25Store ? score : 0,
            hybridScore: score
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        fixedCalendar.date(from: DateComponents(
            calendar: fixedCalendar,
            timeZone: fixedCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
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

    func lastTimeoutSeconds() async -> TimeInterval? {
        await recorder.lastValue()
    }

    func timeoutCount() async -> Int {
        await recorder.count()
    }

    func lastQueries() async -> [String] {
        await queryRecorder.lastValue()
    }

    func allQueries() async -> [[String]] {
        await queryRecorder.allValues()
    }
}

private final class FakeLexicalRetriever: LexicalMemoryRetrieving, @unchecked Sendable {
    private let hits: [MemoryEvidenceHit]
    private let queryRecorder = QueryRecorder()

    init(hits: [MemoryEvidenceHit]) {
        self.hits = hits
    }

    func retrieve(queries: [String], scope: MemoryQueryScope, limit: Int) async -> [MemoryEvidenceHit] {
        await queryRecorder.record(queries)
        return Array(hits.prefix(limit))
    }

    func callCount() async -> Int {
        await queryRecorder.count()
    }

    func lastQueries() async -> [String] {
        await queryRecorder.lastValue()
    }

    func allQueries() async -> [[String]] {
        await queryRecorder.allValues()
    }
}

private final class FakePlanner: MemoryQueryPlanning, @unchecked Sendable {
    private let result: MemoryQueryPlanResult?
    private let recorder = TimeoutRecorder()

    init(result: MemoryQueryPlanResult?) {
        self.result = result
    }

    func plan(
        question: String,
        now: Date,
        detailLevel: MemoryQueryDetailLevel,
        timeZone: TimeZone,
        timeoutSeconds: TimeInterval
    ) async -> MemoryQueryPlanResult? {
        await recorder.record(timeoutSeconds)
        return result
    }

    func lastTimeoutSeconds() async -> TimeInterval? {
        await recorder.lastValue()
    }
}

private final class FakeAnswerer: MemoryQueryAnswering, @unchecked Sendable {
    private let result: MemoryQueryAnswerResult?
    private let recorder = TimeoutRecorder()

    init(result: MemoryQueryAnswerResult?) {
        self.result = result
    }

    func answer(
        question: String,
        scope: MemoryQueryScope,
        detailLevel: MemoryQueryDetailLevel,
        now: Date,
        timeZone: TimeZone,
        mem0Evidence: [MemoryEvidenceHit],
        bm25Evidence: [MemoryEvidenceHit],
        timeoutSeconds: TimeInterval
    ) async -> MemoryQueryAnswerResult? {
        await recorder.record(timeoutSeconds)
        return result
    }

    func lastTimeoutSeconds() async -> TimeInterval? {
        await recorder.lastValue()
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

    func count() -> Int {
        values.count
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

    func count() -> Int {
        values.count
    }

    func allValues() -> [[String]] {
        values
    }
}
