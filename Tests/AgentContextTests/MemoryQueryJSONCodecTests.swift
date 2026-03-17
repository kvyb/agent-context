import XCTest
@testable import AgentContext

final class MemoryQueryJSONCodecTests: XCTestCase {
    func testParsePlanSupportsStructuredSteps() {
        let codec = MemoryQueryJSONCodec()
        let text = """
        {
          "detail_level": "concise",
          "steps": [
            {
              "query": "zoom interview",
              "phase": "research",
              "sources": ["bm25"],
              "max_results": 6
            },
            {
              "query": "candidate mikhail baranov interview",
              "phase": "evidence",
              "sources": ["bm25", "mem0"],
              "max_results": 4
            }
          ],
          "timeframe": {
            "start": "2026-03-16T00:00:00Z",
            "end": "2026-03-17T00:00:00Z",
            "label": "2026-03-16"
          }
        }
        """

        let plan = codec.parsePlan(from: text)

        XCTAssertEqual(plan?.detailLevel, .concise)
        XCTAssertEqual(plan?.steps.count, 2)
        XCTAssertEqual(plan?.steps.first?.phase, .research)
        XCTAssertEqual(plan?.steps.first?.sources, [.bm25Store])
        XCTAssertEqual(plan?.steps.first?.maxResults, 6)
        XCTAssertEqual(plan?.steps.last?.sources, [.bm25Store, .mem0Semantic])
    }
}
