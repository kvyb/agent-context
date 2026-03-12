import XCTest
@testable import AboutTimeCLI

final class AppSettingsStoreTests: XCTestCase {
    func testSaveAndLoadSettingsWithOpenRouterKey() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings.default
        settings.openRouterAPIKey = "sk-test"
        settings.captureScreenshots = false

        try AppSettingsStore.save(settings, baseDirectory: directory)

        let loaded = AppSettingsStore.load(baseDirectory: directory, env: [:])
        XCTAssertEqual(loaded.openRouterAPIKey, "sk-test")
        XCTAssertFalse(loaded.captureScreenshots)
    }

    func testResolvedOpenRouterKeyPrefersSettingsThenEnvFallback() {
        var settings = AppSettings.default
        settings.openRouterAPIKey = "from-settings"

        let resolvedFromSettings = AppSettingsStore.resolvedOpenRouterKey(
            settings: settings,
            env: ["OPENROUTER_API_KEY": "from-env"]
        )
        XCTAssertEqual(resolvedFromSettings, "from-settings")

        settings.openRouterAPIKey = nil
        let resolvedFromEnv = AppSettingsStore.resolvedOpenRouterKey(
            settings: settings,
            env: ["OPENROUTER_API_KEY": "from-env"]
        )
        XCTAssertEqual(resolvedFromEnv, "from-env")
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
