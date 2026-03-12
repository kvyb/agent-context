import XCTest
@testable import AgentContext

final class ArtifactAnalysisDecodingTests: XCTestCase {
    func testDecodeArtifactAnalysisWithNewSchemaShape() {
        let input = """
        {
          "description": "Reviewing PR findings in #ai_research_team and checking router FAQ regression notes.",
          "problem": "Regression risk remains for strict golden-label routing.",
          "success": "Semantic LLM-as-judge validation completed.",
          "user_contribution": "User reviewed test metrics and highlighted unresolved routing edge cases.",
          "suggestion_or_decision": "Keep rerank enabled and follow up on remaining regressions.",
          "status": "in_progress",
          "confidence": 0.92,
          "project": "Manychat",
          "workspace": "Slack",
          "task": "Review AI research findings and test results for PR",
          "evidence": ["Channel #ai_research_team", "Message includes router and FAQ results"],
          "entities": ["Manychat", "Slack", "Gemini-3-flash"],
          "insufficient_evidence": false
        }
        """

        let analysis = decodeArtifactAnalysis(from: input)

        XCTAssertEqual(
            analysis.description,
            "Reviewing PR findings in #ai_research_team and checking router FAQ regression notes."
        )
        XCTAssertEqual(analysis.problem, "Regression risk remains for strict golden-label routing.")
        XCTAssertEqual(analysis.success, "Semantic LLM-as-judge validation completed.")
        XCTAssertEqual(
            analysis.userContribution,
            "User reviewed test metrics and highlighted unresolved routing edge cases."
        )
        XCTAssertEqual(
            analysis.suggestionOrDecision,
            "Keep rerank enabled and follow up on remaining regressions."
        )
        XCTAssertEqual(analysis.status, .inProgress)
        XCTAssertEqual(analysis.project, "Manychat")
        XCTAssertEqual(analysis.workspace, "Slack")
        XCTAssertEqual(analysis.task, "Review AI research findings and test results for PR")
        XCTAssertFalse(analysis.insufficientEvidence)
        XCTAssertTrue(analysis.summary.contains("Problem:"))
        XCTAssertTrue(analysis.summary.contains("Success:"))
    }

    func testLowConfidenceDropsProblemAndSuccess() {
        let input = """
        {
          "description": "Slack thread about QA follow-up.",
          "problem": "Build is failing on CI.",
          "success": "All tests passed.",
          "user_contribution": null,
          "suggestion_or_decision": null,
          "status": "blocked",
          "confidence": 0.3,
          "project": "Agent Context",
          "workspace": "Slack",
          "task": "Investigate CI issue",
          "evidence": ["Mentions failing check"],
          "entities": ["Agent Context", "Slack"],
          "insufficient_evidence": false
        }
        """

        let analysis = decodeArtifactAnalysis(from: input)
        XCTAssertNil(analysis.problem)
        XCTAssertNil(analysis.success)
    }

    func testDecodeArtifactAnalysisFallsBackFromLegacySummary() {
        let input = """
        {
          "summary": "Reviewing AI research findings and test results for PR.",
          "transcript": "",
          "entities": ["Manychat", "Slack"],
          "insufficient_evidence": false
        }
        """

        let analysis = decodeArtifactAnalysis(from: input)
        XCTAssertEqual(analysis.description, "Reviewing AI research findings and test results for PR.")
        XCTAssertFalse(analysis.insufficientEvidence)
        XCTAssertEqual(analysis.status, .none)
    }

    func testArtifactAnalysisModelDecodesLegacyStoredPayload() throws {
        let input = """
        {
          "summary": "Working on query performance improvements.",
          "transcript": null,
          "entities": ["SQLite", "BM25"],
          "insufficient_evidence": false,
          "project": "Agent Context",
          "workspace": "Terminal",
          "task": "Optimize query hops",
          "evidence": ["perf test output"]
        }
        """

        let decoded = try JSONDecoder().decode(ArtifactAnalysis.self, from: Data(input.utf8))
        XCTAssertEqual(decoded.description, "Working on query performance improvements.")
        XCTAssertEqual(decoded.summary, "Working on query performance improvements.")
        XCTAssertEqual(decoded.status, .none)
        XCTAssertEqual(decoded.confidence, 0)
        XCTAssertEqual(decoded.project, "Agent Context")
        XCTAssertEqual(decoded.workspace, "Terminal")
    }
}
