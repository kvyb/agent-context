import XCTest
@testable import AgentContext

final class MemoryQueryJSONCodecTests: XCTestCase {
    func testParseAnswerRecoversFromPartialJSONString() {
        let codec = MemoryQueryJSONCodec()
        let text = """
        {
          "answer": "Mikhail showed strong intermediate-level judgment in retrieval evaluation and system design.",
          "key_points": [
            "Used NDCG for retrieval ranking",
            "Talked through GraphRAG trade-offs"
          ],
          "supporting_events": [
            "[2026-03-16 21:34] Candidate discussed GraphRAG trade-offs",
            "[2026-03-16 21:20] Candidate described NDCG-based evaluation"
          ],
          "insufficient_evidence": false
        """

        let payload = codec.parseAnswer(from: text)

        XCTAssertEqual(
            payload?.answer,
            "Mikhail showed strong intermediate-level judgment in retrieval evaluation and system design."
        )
        XCTAssertEqual(payload?.keyPoints.count, 2)
        XCTAssertEqual(payload?.supportingEvents.count, 2)
        XCTAssertEqual(payload?.insufficientEvidence, false)
    }
}
