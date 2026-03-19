import XCTest
@testable import AgentContext

final class ArtifactAnalysisDecodingTests: XCTestCase {
    func testDecodeArtifactAnalysisWithNewSchemaShape() {
        let input = """
        {
          "description": "Reviewing PR findings in #ai_research_team and checking router FAQ regression notes.",
          "content_description": "Slack shows the #ai_research_team channel with router FAQ regression notes and validation updates for a PR discussion.",
          "layout_description": "A Slack conversation fills the center pane, with the channel list on the left and message details in the main column.",
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
          "salient_text": ["#ai_research_team", "router FAQ", "LLM-as-judge"],
          "ui_elements": [
            {"role": "sidebar", "label": "Channels", "value": "#ai_research_team", "region": "left sidebar"},
            {"role": "chat_message", "label": "router FAQ regression notes", "value": "validation updates for PR discussion", "region": "center pane"}
          ],
          "entities": ["Manychat", "Slack", "Gemini-3-flash"],
          "insufficient_evidence": false
        }
        """

        let analysis = decodeArtifactAnalysis(from: input)

        XCTAssertEqual(
            analysis.description,
            "Reviewing PR findings in #ai_research_team and checking router FAQ regression notes."
        )
        XCTAssertEqual(
            analysis.contentDescription,
            "Slack shows the #ai_research_team channel with router FAQ regression notes and validation updates for a PR discussion."
        )
        XCTAssertEqual(
            analysis.layoutDescription,
            "A Slack conversation fills the center pane, with the channel list on the left and message details in the main column."
        )
        XCTAssertEqual(analysis.salientText, ["#ai_research_team", "router FAQ", "LLM-as-judge"])
        XCTAssertEqual(analysis.uiElements.count, 2)
        XCTAssertEqual(analysis.uiElements.first?.role, "sidebar")
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
          "content_description": "Terminal output and profiling notes focus on query performance improvements.",
          "layout_description": "A terminal occupies the center pane with profiling notes visible above the command output.",
          "salient_text": ["BM25", "query hops"],
          "ui_elements": [
            {"role": "terminal", "label": "performance terminal", "value": "BM25 query hops", "region": "center pane"}
          ],
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
        XCTAssertEqual(decoded.contentDescription, "Terminal output and profiling notes focus on query performance improvements.")
        XCTAssertEqual(decoded.layoutDescription, "A terminal occupies the center pane with profiling notes visible above the command output.")
        XCTAssertEqual(decoded.salientText, ["BM25", "query hops"])
        XCTAssertEqual(decoded.uiElements.first?.role, "terminal")
        XCTAssertEqual(decoded.summary, "Working on query performance improvements.")
        XCTAssertEqual(decoded.status, .none)
        XCTAssertEqual(decoded.confidence, 0)
        XCTAssertEqual(decoded.project, "Agent Context")
        XCTAssertEqual(decoded.workspace, "Terminal")
    }
}
