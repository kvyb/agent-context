import XCTest
@testable import AboutTimeCLI

final class MemoryQueryFormatterTests: XCTestCase {
    func testJSONOutputContainsRequiredFields() throws {
        let formatter = MemoryQueryFormatter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = MemoryQueryResult(
            query: "what did i do",
            answer: "Worked on PR 556.",
            keyPoints: ["Reviewed PR 556"],
            supportingEvents: ["2026-03-12: Reviewed ai-service PR"],
            insufficientEvidence: false,
            mem0SemanticCount: 12,
            bm25StoreCount: 8,
            scope: MemoryQueryScope(start: now, end: now.addingTimeInterval(3600), label: "today"),
            generatedAt: now
        )

        let rendered = formatter.render(result, as: .json)
        let data = try XCTUnwrap(rendered.data(using: .utf8))
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let object = try XCTUnwrap(raw as? [String: Any])

        XCTAssertEqual(object["query"] as? String, "what did i do")
        XCTAssertNotNil(object["answer"] as? String)
        XCTAssertNotNil(object["key_points"] as? [String])
        XCTAssertNotNil(object["supporting_events"] as? [String])
        XCTAssertNotNil(object["insufficient_evidence"] as? Bool)
        XCTAssertNotNil(object["sources"] as? [String: Any])
        XCTAssertNotNil(object["time_scope"] as? [String: Any])
        XCTAssertNotNil(object["generated_at"] as? String)
    }

    func testTextOutputContainsSections() {
        let formatter = MemoryQueryFormatter()
        let result = MemoryQueryResult(
            query: "status",
            answer: "Summary.",
            keyPoints: ["Point A"],
            supportingEvents: ["Event A"],
            insufficientEvidence: true,
            mem0SemanticCount: 1,
            bm25StoreCount: 1,
            scope: MemoryQueryScope(start: nil, end: nil, label: nil),
            generatedAt: Date()
        )

        let rendered = formatter.render(result, as: .text)
        XCTAssertTrue(rendered.contains("Summary."))
        XCTAssertTrue(rendered.contains("Key points:"))
        XCTAssertTrue(rendered.contains("Supporting events:"))
        XCTAssertTrue(rendered.contains("Evidence is partial"))
    }
}
