import XCTest
@testable import AgentContext

final class SettingsCLICommandTests: XCTestCase {
    func testParseSetUserAliases() throws {
        let options = try SettingsCLICommand.parse(
            arguments: ["agent-context", "--set-user-aliases", "Jane Doe, @jane, jane doe"]
        )
        XCTAssertEqual(options?.userIdentityAliases, ["Jane Doe", "@jane"])
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(
            try SettingsCLICommand.parse(arguments: ["agent-context", "--set-user-aliases"])
        ) { error in
            XCTAssertEqual(error.localizedDescription, "missing value for --set-user-aliases")
        }
    }

    func testEmptyValueThrows() {
        XCTAssertThrowsError(
            try SettingsCLICommand.parse(arguments: ["agent-context", "--set-user-aliases", " , "])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "no aliases provided; pass a comma-separated list such as \"Jane Doe, @jane\""
            )
        }
    }
}
