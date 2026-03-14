import XCTest
@testable import AgentContext

final class SystemAppDenylistTests: XCTestCase {
    func testDenyByBundleID() {
        XCTAssertTrue(
            SystemAppDenylist.isDenied(
                appName: "loginwindow",
                bundleID: "com.apple.loginwindow"
            )
        )
    }

    func testDenyByKnownSystemAuthBundle() {
        XCTAssertTrue(
            SystemAppDenylist.isDenied(
                appName: "coreautha",
                bundleID: "com.apple.LocalAuthentication.UIAgent"
            )
        )
    }

    func testDenyByNameWhenBundleMissing() {
        XCTAssertTrue(
            SystemAppDenylist.isDenied(
                appName: "coreautha",
                bundleID: nil
            )
        )
    }

    func testAllowNormalApp() {
        XCTAssertFalse(
            SystemAppDenylist.isDenied(
                appName: "Codex",
                bundleID: "com.openai.codex"
            )
        )
    }
}
