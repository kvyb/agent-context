import XCTest
@testable import AgentContext

final class MemoryQueryEvaluationCodecTests: XCTestCase {
    func testParseEvaluationPayload() {
        let codec = MemoryQueryEvaluationCodec()
        let text = """
        {
          "overall_score": 78,
          "query_alignment_score": 4,
          "retrieval_relevance_score": 5,
          "retrieval_coverage_score": 3,
          "groundedness_score": 4,
          "answer_completeness_score": 4,
          "summary": "The system answered the main question well but missed some secondary details.",
          "retrieval_explanation": "The retrieved transcript evidence is highly relevant, but coverage of weaker areas is thinner.",
          "groundedness_explanation": "Most claims are tied to transcript excerpts, though some conclusions are a bit broader than the evidence.",
          "answer_quality_explanation": "The answer addresses the fit question clearly but could map more claims to specific exchanges.",
          "strengths": ["Relevant transcript chunks surfaced", "Judgment stayed mostly grounded"],
          "weaknesses": ["Coverage of weaknesses is light", "Some synthesis is too high-level"],
          "improvement_actions": ["Boost question-answer exchange chunks", "Require explicit evidence citations for judgments"],
          "evidence_gaps": ["Few direct weaknesses surfaced", "No dedicated retrieval for unanswered questions"]
        }
        """

        let evaluation = codec.parse(from: text)

        XCTAssertEqual(evaluation?.overallScore, 78)
        XCTAssertEqual(evaluation?.retrievalRelevanceScore, 5)
        XCTAssertEqual(evaluation?.strengths.count, 2)
        XCTAssertEqual(evaluation?.improvementActions.first, "Boost question-answer exchange chunks")
    }

    func testParseEvaluationPayloadRecoversFromPartialJSONString() {
        let codec = MemoryQueryEvaluationCodec()
        let text = """
        {
          "overall_score": 85,
          "query_alignment_score": 5,
          "retrieval_relevance_score": 4,
          "retrieval_coverage_score": 4,
          "groundedness_score": 5,
          "answer_completeness_score": 4,
          "summary": "The answer is strong overall.",
          "retrieval_explanation": "The retrieved evidence mostly matches the question.",
          "groundedness_explanation": "Claims stay tied to the retrieved transcript excerpts.",
          "answer_quality_explanation": "The answer is clear but could cover missing dimensions more explicitly.",
          "strengths": ["Relevant evidence", "Grounded synthesis"],
          "weaknesses": ["Some repetition", "Coverage could be broader"],
          "improvement_actions": ["Rerank direct transcript chunks higher", "Reduce duplicate support lines"],
          "evidence_gaps": ["Limited explicit rubric", "No interviewer scorecard"
        """

        let evaluation = codec.parse(from: text)

        XCTAssertEqual(evaluation?.overallScore, 85)
        XCTAssertEqual(evaluation?.queryAlignmentScore, 5)
        XCTAssertEqual(evaluation?.strengths, ["Relevant evidence", "Grounded synthesis"])
        XCTAssertEqual(evaluation?.evidenceGaps, ["Limited explicit rubric", "No interviewer scorecard"])
    }
}
