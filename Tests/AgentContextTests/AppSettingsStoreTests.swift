import XCTest
@testable import AgentContext

final class AppSettingsStoreTests: XCTestCase {
    func testSaveAndLoadSettingsWithOpenRouterKey() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings.default
        settings.openRouterAPIKey = "sk-test"
        settings.openRouterModel = "google/gemini-3.1-flash-lite-preview"
        settings.openRouterAudioModel = "openai/gpt-4o-mini-transcribe"
        settings.openRouterTextModel = "openai/gpt-5-mini"
        settings.captureScreenshots = false

        try AppSettingsStore.save(settings, baseDirectory: directory)

        let loaded = AppSettingsStore.load(baseDirectory: directory, env: [:])
        XCTAssertEqual(loaded.openRouterAPIKey, "sk-test")
        XCTAssertEqual(loaded.openRouterModel, "google/gemini-3.1-flash-lite-preview")
        XCTAssertEqual(loaded.openRouterAudioModel, "openai/gpt-4o-mini-transcribe")
        XCTAssertEqual(loaded.openRouterTextModel, "openai/gpt-5-mini")
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

    func testLoadUsesUserAliasEnvFallbackWhenSettingsMissing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = AppSettingsStore.load(
            baseDirectory: directory,
            env: ["AGENT_CONTEXT_USER_ALIASES": "Jane Doe, @jane, jane doe"]
        )
        XCTAssertEqual(loaded.userIdentityAliases, ["Jane Doe", "@jane"])
    }

    func testLoadUsesOpenRouterModelEnvFallbackWhenSettingsMissing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = AppSettingsStore.load(
            baseDirectory: directory,
            env: ["AGENT_CONTEXT_OPENROUTER_MODEL": "anthropic/claude-sonnet-4"]
        )
        XCTAssertEqual(loaded.openRouterModel, "anthropic/claude-sonnet-4")
        XCTAssertEqual(loaded.openRouterAudioModel, "anthropic/claude-sonnet-4")
        XCTAssertEqual(loaded.openRouterTextModel, "anthropic/claude-sonnet-4")
    }

    func testLoadUsesPerModeModelEnvOverrides() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = AppSettingsStore.load(
            baseDirectory: directory,
            env: [
                "AGENT_CONTEXT_OPENROUTER_MODEL": "google/gemini-3.1-flash-lite-preview",
                "AGENT_CONTEXT_OPENROUTER_AUDIO_MODEL": "openai/gpt-4o-mini-transcribe",
                "AGENT_CONTEXT_OPENROUTER_TEXT_MODEL": "openai/gpt-5-mini"
            ]
        )
        XCTAssertEqual(loaded.openRouterModel, "google/gemini-3.1-flash-lite-preview")
        XCTAssertEqual(loaded.openRouterAudioModel, "openai/gpt-4o-mini-transcribe")
        XCTAssertEqual(loaded.openRouterTextModel, "openai/gpt-5-mini")
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
