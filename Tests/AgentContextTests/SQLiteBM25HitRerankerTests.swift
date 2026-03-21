import XCTest
@testable import AgentContext

final class SQLiteBM25HitRerankerTests: XCTestCase {
    func testCallScopedQueryPrefersZoomTranscriptOverRelatedTaskWork() {
        let reranker = SQLiteBM25HitReranker()
        let analysis = MemoryQueryQuestionAnalyzer(scopeParser: MemoryQueryScopeParser()).analyze(
            question: "What did we talk about on the Zoom call with Toly regarding pipelines and AI agents?"
        )

        let zoomTranscript = MemoryEvidenceHit(
            id: "transcript-unit|zoom",
            source: .bm25Store,
            text: "Transcript exchange: S1: What do you think about the integration timeline? S2: We can start over the weekend and sync Monday. Topics: integration, agents. People: Toly Sherbakov",
            appName: "zoom.us",
            project: nil,
            occurredAt: Date(),
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.transcriptUnit.rawValue,
                "app_name": "zoom.us",
                "workspace": "zoom.us",
                "people": "Toly Sherbakov",
                "entities": "Toly Sherbakov|agents|integration",
                "speaker_exchange": "true",
                "speaker_turn_window": "true"
            ],
            semanticScore: 0,
            lexicalScore: 0.35,
            hybridScore: 0.6
        )

        let relatedTask = MemoryEvidenceHit(
            id: "task-segment|codex",
            source: .bm25Store,
            text: "Investigate FAQ pipeline evaluator • Goal: Assess integrating sales-specific FAQ handling into the existing lead qualification pipeline.",
            appName: "Codex",
            project: "ai-service",
            occurredAt: Date(),
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.taskSegment.rawValue,
                "project": "ai-service",
                "task": "Investigate FAQ pipeline evaluator",
                "workspace": "Codex"
            ],
            semanticScore: 0,
            lexicalScore: 0.7,
            hybridScore: 0.9
        )

        let reranked = reranker.rerankedLexicalHits([relatedTask, zoomTranscript], analysis: analysis, limit: 2)
        XCTAssertEqual(reranked.first?.id, zoomTranscript.id)
    }
}
