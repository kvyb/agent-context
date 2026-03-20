import Foundation

struct OpenRouterRuntimeConfig: Sendable {
    let endpoint: URL
    let model: String
    let queryAgentModel: String
    let evaluationModel: String
    let reasoningEffort: String
    let queryAgentReasoningEffort: String?
    let timeoutSeconds: TimeInterval
}

struct MemoryQueryRuntimeConfig: Sendable {
    let timeoutSeconds: TimeInterval?
    let plannerTimeoutSeconds: TimeInterval?
    let answerTimeoutSeconds: TimeInterval?
    let semanticSearchTimeoutSeconds: TimeInterval
}

struct TrackerConfig: Sendable {
    let environment: [String: String]
    let baseDirectory: URL
    let screenshotsDirectory: URL
    let audioDirectory: URL
    let databaseURL: URL
    let retryJournalURL: URL
    let pythonExecutableURL: URL
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
    let memoryQuery: MemoryQueryRuntimeConfig

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
        let projectDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        let bundledMem0Script = Bundle.main.resourceURL?
            .appendingPathComponent("mem0_ingest.py")
        let projectMem0Script = projectDirectory.appendingPathComponent("scripts/mem0_ingest.py")
        let defaultMem0Script = (bundledMem0Script.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }) ?? projectMem0Script
        let mem0ScriptURL = URL(fileURLWithPath: env["AGENT_CONTEXT_MEM0_SCRIPT"]?.nilIfEmpty ?? defaultMem0Script.path)
        let bundledMem0SearchScript = Bundle.main.resourceURL?
            .appendingPathComponent("mem0_search.py")
        let projectMem0SearchScript = projectDirectory.appendingPathComponent("scripts/mem0_search.py")
        let defaultMem0SearchScript = (bundledMem0SearchScript.flatMap {
            fileManager.fileExists(atPath: $0.path) ? $0 : nil
        }) ?? projectMem0SearchScript
        let mem0SearchScriptURL = URL(fileURLWithPath: env["AGENT_CONTEXT_MEM0_SEARCH_SCRIPT"]?.nilIfEmpty ?? defaultMem0SearchScript.path)
        let pythonExecutableURL = resolvePythonExecutable(
            env: env,
            fileManager: fileManager,
            projectDirectory: projectDirectory,
            mem0ScriptURL: mem0ScriptURL
        )

        let openRouterEndpoint = URL(string: env["AGENT_CONTEXT_OPENROUTER_ENDPOINT"] ?? "https://openrouter.ai/api/v1/chat/completions")
            ?? URL(string: "https://openrouter.ai/api/v1/chat/completions")!

        let openRouter = OpenRouterRuntimeConfig(
            endpoint: openRouterEndpoint,
            model: env["AGENT_CONTEXT_OPENROUTER_MODEL"]?.nilIfEmpty ?? AppSettings.defaultOpenRouterModel,
            queryAgentModel: env["AGENT_CONTEXT_OPENROUTER_QUERY_AGENT_MODEL"]?.nilIfEmpty ?? "openai/gpt-5.4-mini",
            evaluationModel: env["AGENT_CONTEXT_OPENROUTER_EVALUATION_MODEL"]?.nilIfEmpty ?? AppSettings.defaultOpenRouterModel,
            reasoningEffort: env["AGENT_CONTEXT_OPENROUTER_REASONING_EFFORT"]?.nilIfEmpty ?? "medium",
            queryAgentReasoningEffort: env["AGENT_CONTEXT_OPENROUTER_QUERY_AGENT_REASONING_EFFORT"]?.nilIfEmpty,
            timeoutSeconds: max(15, TimeInterval(env["AGENT_CONTEXT_OPENROUTER_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 90))
        )
        let memoryQuery = MemoryQueryRuntimeConfig(
            timeoutSeconds: parseOptionalTimeout(env["AGENT_CONTEXT_MEMORY_QUERY_TIMEOUT_SECONDS"]) ?? 60,
            plannerTimeoutSeconds: parseOptionalTimeout(env["AGENT_CONTEXT_MEMORY_QUERY_PLANNER_TIMEOUT_SECONDS"]),
            answerTimeoutSeconds: parseOptionalTimeout(env["AGENT_CONTEXT_MEMORY_QUERY_ANSWER_TIMEOUT_SECONDS"]),
            semanticSearchTimeoutSeconds: min(10, max(2, TimeInterval(env["AGENT_CONTEXT_MEM0_SEARCH_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 6)))
        )

        return TrackerConfig(
            environment: env,
            baseDirectory: baseDirectory,
            screenshotsDirectory: screenshotsDirectory,
            audioDirectory: audioDirectory,
            databaseURL: databaseURL,
            retryJournalURL: retryJournalURL,
            pythonExecutableURL: pythonExecutableURL,
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
            openRouter: openRouter,
            memoryQuery: memoryQuery
        )
    }
}

private func parseOptionalTimeout(_ raw: String?) -> TimeInterval? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
        return nil
    }
    guard let parsed = Double(raw), parsed > 0 else {
        return nil
    }
    return parsed
}

private func resolvePythonExecutable(
    env: [String: String],
    fileManager: FileManager,
    projectDirectory: URL,
    mem0ScriptURL: URL
) -> URL {
    if let configured = env["AGENT_CONTEXT_PYTHON"]?.nilIfEmpty {
        return URL(fileURLWithPath: configured)
    }

    let scriptRoot = mem0ScriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        projectDirectory.appendingPathComponent(".venv/bin/python3"),
        projectDirectory.appendingPathComponent(".venv/bin/python"),
        scriptRoot.appendingPathComponent(".venv/bin/python3"),
        scriptRoot.appendingPathComponent(".venv/bin/python"),
        URL(fileURLWithPath: "/usr/bin/python3")
    ]

    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
        ?? URL(fileURLWithPath: "/usr/bin/python3")
}
