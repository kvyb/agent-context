import XCTest
@testable import AgentContext

final class QueryCLICommandTests: XCTestCase {
    func testParsesQueryWithDefaultFormat() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "--query", "what did i do"])
        XCTAssertEqual(options?.query, "what did i do")
        XCTAssertEqual(options?.outputFormat, .text)
        XCTAssertEqual(options?.requestOptions.sources, Set(MemoryEvidenceSource.allCases))
    }

    func testParsesJSONFormat() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "--query", "status", "--format", "json"])
        XCTAssertEqual(options?.outputFormat, .json)
    }

    func testInvalidFormatThrows() {
        XCTAssertThrowsError(
            try QueryCLICommand.parse(arguments: ["agent-context", "--query", "status", "--format", "yaml"])
        )
    }

    func testNoQueryReturnsNil() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "--cli"])
        XCTAssertNil(options)
    }

    func testMissingQueryValueThrows() {
        XCTAssertThrowsError(
            try QueryCLICommand.parse(arguments: ["agent-context", "--query"])
        )
    }

    func testParsesQuerySubcommandPositional() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "query", "what changed today?", "--json"])
        XCTAssertEqual(options?.query, "what changed today?")
        XCTAssertEqual(options?.outputFormat, .json)
    }

    func testParsesQuerySubcommandQuestionFlag() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "query", "--question", "status", "--format", "text"])
        XCTAssertEqual(options?.query, "status")
        XCTAssertEqual(options?.outputFormat, .text)
    }

    func testParsesExtendedQueryOptions() throws {
        let options = try QueryCLICommand.parse(arguments: [
            "agent-context",
            "query",
            "zoom interview transcript",
            "--source", "bm25",
            "--start", "2026-03-10",
            "--end", "2026-03-16",
            "--max-results", "5",
            "--timeout", "12.5"
        ])

        XCTAssertEqual(options?.requestOptions.sources, [.bm25Store])
        XCTAssertEqual(options?.requestOptions.maxResults, 5)
        XCTAssertEqual(options?.requestOptions.timeoutSeconds ?? 0, 12.5, accuracy: 0.001)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(options?.requestOptions.scopeOverride?.start.map(formatter.string), "2026-03-10")
        XCTAssertEqual(options?.requestOptions.scopeOverride?.end.map(formatter.string), "2026-03-17")
    }

    func testInvalidSourceThrows() {
        XCTAssertThrowsError(
            try QueryCLICommand.parse(arguments: ["agent-context", "query", "status", "--source", "transcripts"])
        )
    }

    func testInvalidDateRangeThrows() {
        XCTAssertThrowsError(
            try QueryCLICommand.parse(arguments: [
                "agent-context",
                "query",
                "status",
                "--start", "2026-03-16",
                "--end", "2026-03-15"
            ])
        )
    }

    func testQuerySubcommandMissingValueThrows() {
        XCTAssertThrowsError(
            try QueryCLICommand.parse(arguments: ["agent-context", "query"])
        )
    }
}
