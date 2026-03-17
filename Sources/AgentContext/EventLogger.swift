import Darwin
import Foundation

final class RuntimeLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agent-context.runtime-log")
    private let fileURL: URL

    init(baseDirectory: URL) {
        let logsDirectory = baseDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        fileURL = logsDirectory.appendingPathComponent("runtime-\(formatter.string(from: Date())).log")
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] [\(level)] \(message)\n"
        queue.async { [fileURL] in
            guard let data = rendered.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        if let data = rendered.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private struct CapturedProcessOutput: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
    let didTimeOut: Bool
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private func normalizedMem0EnvironmentValue(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func makeMem0ProcessEnvironment(
    baseDirectory: URL,
    settings: AppSettings,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var env = baseEnvironment
    env["AGENT_CONTEXT_MEM0_USER_ID"] = settings.mem0UserID
    env["AGENT_CONTEXT_MEM0_AGENT_ID"] = settings.mem0AgentID
    env["AGENT_CONTEXT_MEM0_COLLECTION"] = settings.mem0Collection
    env["AGENT_CONTEXT_MEM0_HISTORY_DB_PATH"] = baseDirectory
        .appendingPathComponent("reports/mem0-history.sqlite").path
    env["AGENT_CONTEXT_MEM0_QDRANT_PATH"] = baseDirectory
        .appendingPathComponent("reports/mem0-qdrant").path
    env["AGENT_CONTEXT_OPENROUTER_BASE_URL"] = env["AGENT_CONTEXT_OPENROUTER_BASE_URL"] ?? "https://openrouter.ai/api/v1"

    if let key = normalizedMem0EnvironmentValue(settings.openRouterAPIKey) {
        env["AGENT_CONTEXT_OPENROUTER_API_KEY"] = key
        env["OPENROUTER_API_KEY"] = key
        env["OPENAI_API_KEY"] = key
    }

    if let model = normalizedMem0EnvironmentValue(settings.openRouterTextModel)
        ?? normalizedMem0EnvironmentValue(settings.openRouterModel)
        ?? normalizedMem0EnvironmentValue(env["AGENT_CONTEXT_OPENROUTER_TEXT_MODEL"])
        ?? normalizedMem0EnvironmentValue(env["AGENT_CONTEXT_OPENROUTER_MODEL"]) {
        env["AGENT_CONTEXT_MEM0_LLM_MODEL"] = model
    }

    env["OPENAI_BASE_URL"] = env["AGENT_CONTEXT_OPENROUTER_BASE_URL"]
    env["AGENT_CONTEXT_MEM0_EMBED_MODEL"] = env["AGENT_CONTEXT_MEM0_EMBED_MODEL"] ?? "openai/text-embedding-3-small"
    return env
}

private func runProcessAndCapture(
    _ process: Process,
    stdin: Data?,
    timeoutSeconds: TimeInterval? = nil
) throws -> CapturedProcessOutput {
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    // Close parent-side write handles so reader threads can reach EOF reliably.
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()

    let outputBox = DataBox()
    let errorBox = DataBox()
    let drainGroup = DispatchGroup()

    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        outputBox.set(data)
        drainGroup.leave()
    }

    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        errorBox.set(data)
        drainGroup.leave()
    }

    if let stdin {
        inputPipe.fileHandleForWriting.write(stdin)
    }
    try? inputPipe.fileHandleForWriting.close()

    let waitSemaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        waitSemaphore.signal()
    }

    let didTimeOut: Bool
    if let timeoutSeconds {
        let result = waitSemaphore.wait(timeout: .now() + timeoutSeconds)
        didTimeOut = result == .timedOut
        if didTimeOut {
            if process.isRunning {
                process.interrupt()
            }
            if process.isRunning {
                process.terminate()
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = waitSemaphore.wait(timeout: .now() + 2)
        }
    } else {
        waitSemaphore.wait()
        didTimeOut = false
    }
    _ = drainGroup.wait(timeout: .now() + 2)

    let outputText = String(data: outputBox.value(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorText = String(data: errorBox.value(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return CapturedProcessOutput(
        terminationStatus: process.terminationStatus,
        stdout: outputText,
        stderr: errorText,
        didTimeOut: didTimeOut
    )
}

final class Mem0Ingestor: @unchecked Sendable {
    private let pythonExecutableURL: URL
    private let scriptURL: URL
    private let baseDirectory: URL
    private let logger: RuntimeLog

    init(pythonExecutableURL: URL, scriptURL: URL, baseDirectory: URL, logger: RuntimeLog) {
        self.pythonExecutableURL = pythonExecutableURL
        self.scriptURL = scriptURL
        self.baseDirectory = baseDirectory
        self.logger = logger
    }

    func ingest(payload: MemoryPayload, settings: AppSettings) -> (status: String, responseJSON: String?) {
        guard settings.mem0Enabled else {
            return ("disabled", nil)
        }

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return ("script_missing", "{\"error\":\"mem0 script missing\"}")
        }

        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = [scriptURL.path]

        process.environment = makeMem0ProcessEnvironment(baseDirectory: baseDirectory, settings: settings)

        let inputData = try? JSONEncoder().encode(payload)
        let capture: CapturedProcessOutput
        do {
            capture = try runProcessAndCapture(process, stdin: inputData)
        } catch {
            logger.error("Mem0 script launch failed: \(error.localizedDescription)")
            return ("launch_failed", "{\"error\":\"\(error.localizedDescription)\"}")
        }

        if capture.terminationStatus == 0 {
            return ("ok", capture.stdout.nilIfEmpty)
        }

        let errorJSON = "{\"stderr\":\"\((capture.stderr.nilIfEmpty ?? "unknown error").replacingOccurrences(of: "\"", with: "\\\""))\"}"
        return ("failed", capture.stdout.nilIfEmpty ?? errorJSON)
    }
}

final class Mem0Searcher: @unchecked Sendable {
    private let pythonExecutableURL: URL
    private let scriptURL: URL
    private let baseDirectory: URL
    private let logger: RuntimeLog

    init(pythonExecutableURL: URL, scriptURL: URL, baseDirectory: URL, logger: RuntimeLog) {
        self.pythonExecutableURL = pythonExecutableURL
        self.scriptURL = scriptURL
        self.baseDirectory = baseDirectory
        self.logger = logger
    }

    func searchBatch(
        queries: [String],
        start: Date?,
        end: Date?,
        limit: Int,
        timeoutSeconds: TimeInterval?,
        settings: AppSettings
    ) -> [Mem0SearchHit] {
        guard settings.mem0Enabled else {
            return []
        }

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return []
        }

        let normalizedQueries = normalizeQueries(queries)
        guard !normalizedQueries.isEmpty else {
            return []
        }

        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = [scriptURL.path]

        process.environment = makeMem0ProcessEnvironment(baseDirectory: baseDirectory, settings: settings)

        let input: [String: Any] = [
            "queries": normalizedQueries,
            "query": normalizedQueries[0],
            "start": start.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "end": end.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "limit": max(1, min(100, limit))
        ]

        let inputData = try? JSONSerialization.data(withJSONObject: input, options: [])
        let capture: CapturedProcessOutput
        let startedAt = Date()
        logger.info(
            "Mem0 search started: query_count=\(normalizedQueries.count) limit=\(max(1, min(100, limit))) timeout=\(String(format: "%.1fs", timeoutSeconds ?? 0)) start=\(start.map { ISO8601DateFormatter().string(from: $0) } ?? "-") end=\(end.map { ISO8601DateFormatter().string(from: $0) } ?? "-")"
        )
        do {
            capture = try runProcessAndCapture(process, stdin: inputData, timeoutSeconds: timeoutSeconds)
        } catch {
            logger.error("Mem0 search launch failed: \(error.localizedDescription)")
            return []
        }

        let duration = Date().timeIntervalSince(startedAt)
        if capture.didTimeOut {
            logger.error("Mem0 search timed out after \(String(format: "%.2fs", duration)); falling back to other sources.")
            return []
        }

        guard capture.terminationStatus == 0 else {
            if !capture.stderr.isEmpty {
                logger.error("Mem0 search failed: \(capture.stderr)")
            }
            return []
        }

        guard let payloadData = capture.stdout.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: payloadData, options: []),
              let object = raw as? [String: Any],
              (object["status"] as? String) == "ok",
              let hits = object["hits"] as? [[String: Any]]
        else {
            if !capture.stdout.isEmpty || !capture.stderr.isEmpty {
                logger.error("Mem0 search returned unreadable output after \(String(format: "%.2fs", duration)).")
            }
            return []
        }

        logger.info("Mem0 search finished in \(String(format: "%.2fs", duration)) with \(hits.count) raw hits.")

        return hits.compactMap { hit in
            let metadataObject = hit["metadata"] as? [String: Any] ?? [:]
            let metadata = metadataObject.reduce(into: [String: String]()) { acc, pair in
                if let value = pair.value as? String {
                    acc[pair.key] = value
                } else if let value = pair.value as? NSNumber {
                    acc[pair.key] = value.stringValue
                }
            }

            let occurredAt: Date?
            if let rawTime = metadata["occurred_at"] {
                occurredAt = ISO8601DateFormatter().date(from: rawTime)
            } else if let rawTime = hit["occurred_at"] as? String {
                occurredAt = ISO8601DateFormatter().date(from: rawTime)
            } else {
                occurredAt = nil
            }

            let memory = (hit["memory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !memory.isEmpty else { return nil }

            return Mem0SearchHit(
                score: hit["score"] as? Double,
                memory: memory,
                appName: (hit["app_name"] as? String)?.nilIfEmpty ?? metadata["app_name"]?.nilIfEmpty,
                project: (hit["project"] as? String)?.nilIfEmpty ?? metadata["project"]?.nilIfEmpty,
                occurredAt: occurredAt,
                metadata: metadata
            )
        }
    }

    func search(
        query: String,
        start: Date?,
        end: Date?,
        limit: Int,
        settings: AppSettings
    ) -> [Mem0SearchHit] {
        searchBatch(
            queries: [query],
            start: start,
            end: end,
            limit: limit,
            timeoutSeconds: nil,
            settings: settings
        )
    }
    private func normalizeQueries(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for query in queries {
            guard let normalizedQuery = normalizedMem0EnvironmentValue(query) else { continue }
            let key = normalizedQuery.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(normalizedQuery)
            if output.count >= 10 {
                break
            }
        }
        return output
    }
}
