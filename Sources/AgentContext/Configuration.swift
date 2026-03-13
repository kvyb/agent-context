import Foundation

struct OpenRouterRuntimeConfig: Sendable {
    let endpoint: URL
    let model: String
    let reasoningEffort: String
    let timeoutSeconds: TimeInterval
}

struct TrackerConfig: Sendable {
    let environment: [String: String]
    let baseDirectory: URL
    let screenshotsDirectory: URL
    let audioDirectory: URL
    let databaseURL: URL
    let retryJournalURL: URL
    let mem0ScriptURL: URL
    let mem0SearchScriptURL: URL

    let screenshotActivationDelaySeconds: TimeInterval
    let screenshotWhileActiveSeconds: TimeInterval
    let screenshotMaxDimension: Int
    let screenshotQuality: Double

    let reportIntervalMinutes: Int
    let audioChunkSeconds: TimeInterval
    let maxRetryAttempts: Int
    let retryBaseDelaySeconds: TimeInterval
    let shutdownDrainTimeoutSeconds: TimeInterval

    let openRouter: OpenRouterRuntimeConfig

    static func fromEnvironment() -> TrackerConfig {
        let env = runtimeEnvironment()
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        let baseDirectory: URL
        if let configured = env["AGENT_CONTEXT_HOME"]?.nilIfEmpty {
            baseDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            baseDirectory = home.appendingPathComponent(".agent-context", isDirectory: true)
        }

        let screenshotsDirectory = baseDirectory.appendingPathComponent("screenshots", isDirectory: true)
        let audioDirectory = baseDirectory.appendingPathComponent("audio/system", isDirectory: true)
        let reportsDirectory = baseDirectory.appendingPathComponent("reports", isDirectory: true)
        let databaseURL = reportsDirectory.appendingPathComponent("activity.sqlite")
        let retryJournalURL = reportsDirectory.appendingPathComponent("retry-journal.json")

        let bundledMem0Script = Bundle.main.resourceURL?
            .appendingPathComponent("mem0_ingest.py")
        let projectMem0Script = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("scripts/mem0_ingest.py")
        let defaultMem0Script = (bundledMem0Script.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }) ?? projectMem0Script
        let mem0ScriptURL = URL(fileURLWithPath: env["AGENT_CONTEXT_MEM0_SCRIPT"]?.nilIfEmpty ?? defaultMem0Script.path)
        let bundledMem0SearchScript = Bundle.main.resourceURL?
            .appendingPathComponent("mem0_search.py")
        let projectMem0SearchScript = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("scripts/mem0_search.py")
        let defaultMem0SearchScript = (bundledMem0SearchScript.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }) ?? projectMem0SearchScript
        let mem0SearchScriptURL = URL(fileURLWithPath: env["AGENT_CONTEXT_MEM0_SEARCH_SCRIPT"]?.nilIfEmpty ?? defaultMem0SearchScript.path)

        let openRouterEndpoint = URL(string: env["AGENT_CONTEXT_OPENROUTER_ENDPOINT"] ?? "https://openrouter.ai/api/v1/chat/completions")
            ?? URL(string: "https://openrouter.ai/api/v1/chat/completions")!

        let openRouter = OpenRouterRuntimeConfig(
            endpoint: openRouterEndpoint,
            model: env["AGENT_CONTEXT_OPENROUTER_MODEL"]?.nilIfEmpty ?? AppSettings.defaultOpenRouterModel,
            reasoningEffort: env["AGENT_CONTEXT_OPENROUTER_REASONING_EFFORT"]?.nilIfEmpty ?? "medium",
            timeoutSeconds: max(15, TimeInterval(env["AGENT_CONTEXT_OPENROUTER_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 90))
        )

        return TrackerConfig(
            environment: env,
            baseDirectory: baseDirectory,
            screenshotsDirectory: screenshotsDirectory,
            audioDirectory: audioDirectory,
            databaseURL: databaseURL,
            retryJournalURL: retryJournalURL,
            mem0ScriptURL: mem0ScriptURL,
            mem0SearchScriptURL: mem0SearchScriptURL,
            screenshotActivationDelaySeconds: max(1, TimeInterval(env["AGENT_CONTEXT_SCREENSHOT_AFTER_ACTIVATION_SECONDS"].flatMap(Double.init) ?? 3)),
            screenshotWhileActiveSeconds: max(5, TimeInterval(env["AGENT_CONTEXT_SCREENSHOT_WHILE_ACTIVE_SECONDS"].flatMap(Double.init) ?? 30)),
            screenshotMaxDimension: min(4096, max(800, env["AGENT_CONTEXT_SCREENSHOT_MAX_DIMENSION"].flatMap(Int.init) ?? 1800)),
            screenshotQuality: min(0.95, max(0.2, env["AGENT_CONTEXT_SCREENSHOT_QUALITY"].flatMap(Double.init) ?? 0.55)),
            reportIntervalMinutes: min(60, max(10, env["AGENT_CONTEXT_REPORT_INTERVAL_MINUTES"].flatMap(Int.init) ?? 10)),
            audioChunkSeconds: min(600, max(30, TimeInterval(env["AGENT_CONTEXT_AUDIO_CHUNK_SECONDS"].flatMap(Double.init) ?? 120))),
            maxRetryAttempts: min(12, max(2, env["AGENT_CONTEXT_MAX_RETRY_ATTEMPTS"].flatMap(Int.init) ?? 6)),
            retryBaseDelaySeconds: min(600, max(5, TimeInterval(env["AGENT_CONTEXT_RETRY_BASE_DELAY_SECONDS"].flatMap(Double.init) ?? 15))),
            shutdownDrainTimeoutSeconds: min(120, max(5, TimeInterval(env["AGENT_CONTEXT_SHUTDOWN_DRAIN_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 30))),
            openRouter: openRouter
        )
    }
}
