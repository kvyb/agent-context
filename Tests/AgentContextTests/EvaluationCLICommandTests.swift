import XCTest
@testable import AgentContext

final class EvaluationCLICommandTests: XCTestCase {
    func testParsesEvaluateQuerySubcommand() throws {
        let options = try EvaluationCLICommand.parse(arguments: [
            "agent-context",
            "evaluate-query",
            "what did i do on 2026-03-16?",
            "--json",
            "--timeout", "20"
        ])

        XCTAssertEqual(options?.query, "what did i do on 2026-03-16?")
        XCTAssertEqual(options?.outputFormat, .json)
        XCTAssertEqual(options?.requestOptions.timeoutSeconds ?? 0, 20, accuracy: 0.001)
    }

    func testParsesEvalQueryAlias() throws {
        let options = try EvaluationCLICommand.parse(arguments: [
            "agent-context",
            "eval-query",
            "status"
        ])

        XCTAssertEqual(options?.query, "status")
    }
}
