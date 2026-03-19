import XCTest
@testable import AgentContext

final class Mem0ResultRerankerTests: XCTestCase {
    func testRerankerPrefersProjectAndBlockerFitOverRawSemanticScore() {
        let reranker = Mem0ResultReranker()
        let scopeParser = MemoryQueryScopeParser()
        let scope = scopeParser.inferScope(for: "manychat blockers on 2026-03-16")

        let hits = [
            Mem0SearchHit(
                score: 0.91,
                memory: "OpenTulpa tunnel deployment progressed after restarting the local bridge.",
                appName: "Warp",
                project: "OpenTulpa",
                occurredAt: ISO8601DateFormatter().date(from: "2026-03-16T10:00:00Z"),
                metadata: [
                    "scope": "task_segment",
                    "categories": "work"
                ]
            ),
            Mem0SearchHit(
                score: 0.76,
                memory: "ManyChat webhook rollout was blocked by a regression in lead qualification and required a retry plan.",
                appName: "Slack",
                project: "ManyChat",
                occurredAt: ISO8601DateFormatter().date(from: "2026-03-16T09:30:00Z"),
                metadata: [
                    "scope": "task_segment",
                    "categories": "work|blocker",
                    "entities": "ManyChat|Webhook"
                ]
            )
        ]

        let reranked = reranker.rerank(
            hits: hits,
            queries: ["what blockers happened in manychat on 2026-03-16"],
            scope: scope,
            limit: 5
        )

        XCTAssertEqual(reranked.first?.project, "ManyChat")
        XCTAssertTrue((reranked.first?.metadata["mem0_domain_boost"]).flatMap(Double.init) ?? 0 > 0)
    }

    func testRerankerPrefersInterviewMemoriesForTranscriptQuestions() {
        let reranker = Mem0ResultReranker()
        let scope = MemoryQueryScope(start: nil, end: nil, label: nil)

        let hits = [
            Mem0SearchHit(
                score: 0.88,
                memory: "Reminder to analyze the interview transcript later and send follow-up notes.",
                appName: "Telegram",
                project: nil,
                occurredAt: ISO8601DateFormatter().date(from: "2026-03-16T15:00:00Z"),
                metadata: [
                    "scope": "memory_summary",
                    "categories": "work|interview"
                ]
            ),
            Mem0SearchHit(
                score: 0.71,
                memory: "Interview transcript: candidate explained GraphRAG tradeoffs, NDCG evaluation, and Grafana monitoring for production systems.",
                appName: "zoom.us",
                project: "AI Core",
                occurredAt: ISO8601DateFormatter().date(from: "2026-03-16T13:10:00Z"),
                metadata: [
                    "scope": "transcript_unit",
                    "categories": "meeting|interview|transcript"
                ]
            )
        ]

        let reranked = reranker.rerank(
            hits: hits,
            queries: ["how well did the candidate do in the interview transcript"],
            scope: scope,
            limit: 5
        )

        XCTAssertTrue(reranked.first?.text.contains("Interview transcript") == true)
        XCTAssertEqual(reranked.first?.appName, "zoom.us")
    }
}
