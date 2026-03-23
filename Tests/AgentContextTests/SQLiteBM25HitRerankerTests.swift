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

    func testBroadWorkSummaryDiversifiesAcrossProjects() {
        let reranker = SQLiteBM25HitReranker()
        let analysis = MemoryQueryQuestionAnalyzer(scopeParser: MemoryQueryScopeParser()).analyze(
            question: "What did I work on today?"
        )
        let now = Date()

        let latestZoom = MemoryEvidenceHit(
            id: "task-segment|zoom-latest",
            source: .bm25Store,
            text: "Task: Attend AI features weekly grooming meeting | Status: done | Project: AI features",
            appName: "zoom.us",
            project: "AI features",
            occurredAt: now,
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.taskSegment.rawValue,
                "project": "AI features",
                "task": "Attend AI features weekly grooming meeting"
            ],
            semanticScore: 0,
            lexicalScore: 0,
            hybridScore: 0.85
        )

        let latestZoomFollowup = MemoryEvidenceHit(
            id: "task-segment|zoom-followup",
            source: .bm25Store,
            text: "Task: Define lead qualification escalation triggers | Status: in_progress | Project: Lead Qualification Skill",
            appName: "zoom.us",
            project: "Lead Qualification Skill",
            occurredAt: now.addingTimeInterval(-120),
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.taskSegment.rawValue,
                "project": "Lead Qualification Skill",
                "task": "Define lead qualification escalation triggers"
            ],
            semanticScore: 0,
            lexicalScore: 0,
            hybridScore: 0.84
        )

        let latestCodex = MemoryEvidenceHit(
            id: "task-segment|codex-latest",
            source: .bm25Store,
            text: "Task: Refactor pitch worker into planner matcher writer critic loop | Status: done | Project: playbox-platform",
            appName: "Codex",
            project: "playbox-platform",
            occurredAt: now.addingTimeInterval(-300),
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.taskSegment.rawValue,
                "project": "playbox-platform",
                "task": "Refactor pitch worker"
            ],
            semanticScore: 0,
            lexicalScore: 0,
            hybridScore: 0.83
        )

        let staleArtifact = MemoryEvidenceHit(
            id: "artifact|old",
            source: .bm25Store,
            text: "Artifact showing a docs page about storage migration.",
            appName: "Notion",
            project: "Old project",
            occurredAt: now.addingTimeInterval(-86_400),
            metadata: [
                "retrieval_unit": LexicalRetrievalUnit.artifactEvidence.rawValue
            ],
            semanticScore: 0,
            lexicalScore: 0.95,
            hybridScore: 1.1
        )

        let reranked = reranker.rerankedLexicalHits(
            [staleArtifact, latestZoom, latestZoomFollowup, latestCodex],
            analysis: analysis,
            limit: 3
        )

        XCTAssertEqual(reranked.first?.id, latestZoom.id)
        XCTAssertFalse(reranked.prefix(2).contains { $0.id == staleArtifact.id })
        XCTAssertEqual(Set(reranked.prefix(2).compactMap(\.project)).count, 2)
    }
}
