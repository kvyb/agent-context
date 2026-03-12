import XCTest
@testable import AgentContext

final class BM25RankerTests: XCTestCase {
    func testScoresAreDeterministic() {
        let ranker = BM25Ranker()
        let docs = [
            ["manychat", "ai", "service", "review", "pr"],
            ["manychat", "grafana", "access", "eval", "platform"],
            ["music", "player", "youtube"]
        ]
        let query = ["manychat", "service", "pr"]

        let first = ranker.score(documents: docs, queryTerms: query)
        let second = ranker.score(documents: docs, queryTerms: query)
        XCTAssertEqual(first.count, second.count)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.000_000_1)
        }
    }

    func testRelevantDocumentRanksHigher() {
        let ranker = BM25Ranker()
        let docs = [
            ["manychat", "ai", "service", "review", "pr", "556"],
            ["manychat", "notes", "meeting"],
            ["telegram", "chat"]
        ]
        let query = ["manychat", "service", "pr"]

        let scores = ranker.score(documents: docs, queryTerms: query)
        XCTAssertGreaterThan(scores[0], scores[1])
        XCTAssertGreaterThan(scores[1], scores[2])
    }
}
