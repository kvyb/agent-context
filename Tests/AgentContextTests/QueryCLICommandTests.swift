import XCTest
@testable import AgentContext

final class QueryCLICommandTests: XCTestCase {
    func testParsesQueryWithDefaultFormat() throws {
        let options = try QueryCLICommand.parse(arguments: ["agent-context", "--query", "what did i do"])
        XCTAssertEqual(options?.query, "what did i do")
        XCTAssertEqual(options?.outputFormat, .text)
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
}
