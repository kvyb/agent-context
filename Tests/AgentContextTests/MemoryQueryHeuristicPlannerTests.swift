import XCTest
@testable import AgentContext

final class MemoryQueryHeuristicPlannerTests: XCTestCase {
    func testProfileMarksDateBoundFacetQueriesAsDetailed() {
        let planner = MemoryQueryHeuristicPlanner(scopeParser: MemoryQueryScopeParser())

        let profile = planner.profile(
            for: "what did user do for manychat between 2026-03-15 and 2026-03-17? What are the projects, tasks, main takeaways and struggles?"
        )

        XCTAssertTrue(profile.prefersDetailedAnswer)
        XCTAssertEqual(profile.requestedDimensions, ["projects", "tasks", "takeaways", "struggles"])
        XCTAssertTrue(profile.focusTerms.contains("manychat"))
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
        XCTAssertTrue(queries.contains("manychat struggles"))
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

    func testProfileMarksInterviewFitQueriesAsDetailed() {
        let planner = MemoryQueryHeuristicPlanner(scopeParser: MemoryQueryScopeParser())

        let profile = planner.profile(
            for: "How well does the candidate from the zoom interview last night match an intermediate level? What questions were answered, and what are the strengths, weaknesses, and fit?"
        )

        XCTAssertTrue(profile.prefersDetailedAnswer)
        XCTAssertTrue(profile.seeksEvaluation)
        XCTAssertEqual(profile.requestedDimensions, ["questions answered", "strengths", "weaknesses", "fit"])
    }

    func testProfileExtractsGenericRequestedDimensions() {
        let planner = MemoryQueryHeuristicPlanner(scopeParser: MemoryQueryScopeParser())

        let profile = planner.profile(
            for: "What were my main blockers this week in AI Core work? Include projects, people involved, and next steps."
        )

        XCTAssertEqual(profile.requestedDimensions, ["projects", "people involved", "next steps"])
        XCTAssertTrue(profile.focusTerms.contains("core"))
    }
}
