import XCTest
@testable import AgentContext

final class MemoryQueryHeuristicPlannerTests: XCTestCase {
    func testProfileMarksDateBoundFacetQueriesAsDetailed() {
        let planner = MemoryQueryHeuristicPlanner(scopeParser: MemoryQueryScopeParser())

        let profile = planner.profile(
            for: "what did user do for manychat between 2026-03-15 and 2026-03-17? What are the projects, tasks, main takeaways and struggles?"
        )

        XCTAssertTrue(profile.prefersDetailedAnswer)
        XCTAssertEqual(profile.requestedFacets, ["projects", "tasks", "takeaways", "blockers"])
    }

    func testDefaultPlanStepsIncludeFacetQueriesForAnalyticalQuestions() {
        let planner = MemoryQueryHeuristicPlanner(scopeParser: MemoryQueryScopeParser())
        let profile = planner.profile(
            for: "what did user do for manychat between 2026-03-15 and 2026-03-17? What are the projects, tasks, main takeaways and struggles?"
        )

        let steps = planner.defaultPlanSteps(
            for: "what did user do for manychat between 2026-03-15 and 2026-03-17? What are the projects, tasks, main takeaways and struggles?",
            requestOptions: .default,
            profile: profile
        )

        let queries = Set(steps.map { $0.query.lowercased() })
        XCTAssertTrue(queries.contains("manychat projects"))
        XCTAssertTrue(queries.contains("manychat tasks"))
        XCTAssertTrue(queries.contains("manychat takeaways"))
        XCTAssertTrue(queries.contains("manychat blockers"))
    }

    func testQueryTermsStripExplicitDateNoise() {
        let parser = MemoryQueryScopeParser()

        let terms = parser.queryTerms(
            for: "what did user do for manychat between 15th and 17th of March? What are the projects, tasks, main takeaways and struggles?"
        )

        XCTAssertTrue(terms.contains("manychat"))
        XCTAssertFalse(terms.contains("15th"))
        XCTAssertFalse(terms.contains("17th"))
        XCTAssertFalse(terms.contains("march"))
    }
}
