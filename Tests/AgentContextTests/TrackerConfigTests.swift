import XCTest
@testable import AgentContext

final class TrackerConfigTests: XCTestCase {
    func testDefaultsMatchVNextCadence() {
        withEnvironmentUnset([
            "AGENT_CONTEXT_SCREENSHOT_AFTER_ACTIVATION_SECONDS",
            "AGENT_CONTEXT_SCREENSHOT_WHILE_ACTIVE_SECONDS",
            "AGENT_CONTEXT_AUDIO_CHUNK_SECONDS",
            "AGENT_CONTEXT_REPORT_INTERVAL_MINUTES"
        ]) {
            let config = TrackerConfig.fromEnvironment()
            XCTAssertEqual(config.screenshotActivationDelaySeconds, 3)
            XCTAssertEqual(config.screenshotWhileActiveSeconds, 30)
            XCTAssertEqual(config.audioChunkSeconds, 120)
            XCTAssertEqual(config.reportIntervalMinutes, 10)
        }
    }

    func testClampsCadenceAndRetryValues() {
        withEnvironment([
            "AGENT_CONTEXT_SCREENSHOT_AFTER_ACTIVATION_SECONDS": "0",
            "AGENT_CONTEXT_SCREENSHOT_WHILE_ACTIVE_SECONDS": "3",
            "AGENT_CONTEXT_AUDIO_CHUNK_SECONDS": "999",
            "AGENT_CONTEXT_MAX_RETRY_ATTEMPTS": "99",
            "AGENT_CONTEXT_RETRY_BASE_DELAY_SECONDS": "1"
        ]) {
            let config = TrackerConfig.fromEnvironment()
            XCTAssertEqual(config.screenshotActivationDelaySeconds, 1)
            XCTAssertEqual(config.screenshotWhileActiveSeconds, 5)
            XCTAssertEqual(config.audioChunkSeconds, 600)
            XCTAssertEqual(config.maxRetryAttempts, 12)
            XCTAssertEqual(config.retryBaseDelaySeconds, 5)
        }
    }

    func testOpenRouterDefaults() {
        withEnvironmentUnset([
            "AGENT_CONTEXT_OPENROUTER_ENDPOINT",
            "AGENT_CONTEXT_OPENROUTER_MODEL",
            "AGENT_CONTEXT_OPENROUTER_REASONING_EFFORT"
        ]) {
            let config = TrackerConfig.fromEnvironment()
            XCTAssertEqual(config.openRouter.endpoint.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(config.openRouter.model, "google/gemini-3.1-flash-lite-preview")
            XCTAssertEqual(config.openRouter.reasoningEffort, "medium")
        }
    }

    private func withEnvironment(_ values: [String: String], run body: () -> Void) {
        var previous: [String: String?] = [:]
        for (key, value) in values {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }

        body()

        for (key, old) in previous {
            if let old {
                setenv(key, old, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private func withEnvironmentUnset(_ keys: [String], run body: () -> Void) {
        var previous: [String: String?] = [:]
        for key in keys {
            previous[key] = ProcessInfo.processInfo.environment[key]
            unsetenv(key)
        }

        body()

        for (key, old) in previous {
            if let old {
                setenv(key, old, 1)
            } else {
                unsetenv(key)
            }
        }
    }
}
