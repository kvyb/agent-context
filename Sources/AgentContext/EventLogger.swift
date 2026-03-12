import Foundation

final class RuntimeLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "about-time.runtime-log")
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
        print(rendered, terminator: "")
    }
}

final class Mem0Ingestor: @unchecked Sendable {
    private let scriptURL: URL
    private let baseDirectory: URL
    private let logger: RuntimeLog

    init(scriptURL: URL, baseDirectory: URL, logger: RuntimeLog) {
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["ABOUT_TIME_MEM0_USER_ID"] = settings.mem0UserID
        env["ABOUT_TIME_MEM0_AGENT_ID"] = settings.mem0AgentID
        env["ABOUT_TIME_MEM0_COLLECTION"] = settings.mem0Collection
        env["ABOUT_TIME_MEM0_HISTORY_DB_PATH"] = baseDirectory
            .appendingPathComponent("reports/mem0-history.sqlite").path
        env["ABOUT_TIME_MEM0_QDRANT_PATH"] = baseDirectory
            .appendingPathComponent("reports/mem0-qdrant").path
        env["ABOUT_TIME_OPENROUTER_BASE_URL"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"] ?? "https://openrouter.ai/api/v1"
        if let key = normalized(settings.openRouterAPIKey) {
            env["ABOUT_TIME_OPENROUTER_API_KEY"] = key
            env["OPENROUTER_API_KEY"] = key
            env["OPENAI_API_KEY"] = key
        }
        if let model = normalized(env["ABOUT_TIME_OPENROUTER_MODEL"]) {
            env["ABOUT_TIME_MEM0_LLM_MODEL"] = model
        }
        env["OPENAI_BASE_URL"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"]
        env["OPENAI_API_BASE"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"]
        env["ABOUT_TIME_MEM0_EMBED_MODEL"] = env["ABOUT_TIME_MEM0_EMBED_MODEL"] ?? "openai/text-embedding-3-small"
        process.environment = env

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            logger.error("Mem0 script launch failed: \(error.localizedDescription)")
            return ("launch_failed", "{\"error\":\"\(error.localizedDescription)\"}")
        }

        if let input = try? JSONEncoder().encode(payload) {
            inputPipe.fileHandleForWriting.write(input)
        }
        try? inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        let outputText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return ("ok", outputText)
        }

        let errorJSON = "{\"stderr\":\"\((errorText ?? "unknown error").replacingOccurrences(of: "\"", with: "\\\""))\"}"
        return ("failed", outputText ?? errorJSON)
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

final class Mem0Searcher: @unchecked Sendable {
    private let scriptURL: URL
    private let baseDirectory: URL
    private let logger: RuntimeLog

    init(scriptURL: URL, baseDirectory: URL, logger: RuntimeLog) {
        self.scriptURL = scriptURL
        self.baseDirectory = baseDirectory
        self.logger = logger
    }

    func search(
        query: String,
        start: Date?,
        end: Date?,
        limit: Int,
        settings: AppSettings
    ) -> [Mem0SearchHit] {
        guard settings.mem0Enabled else {
            return []
        }

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["ABOUT_TIME_MEM0_USER_ID"] = settings.mem0UserID
        env["ABOUT_TIME_MEM0_AGENT_ID"] = settings.mem0AgentID
        env["ABOUT_TIME_MEM0_COLLECTION"] = settings.mem0Collection
        env["ABOUT_TIME_MEM0_HISTORY_DB_PATH"] = baseDirectory
            .appendingPathComponent("reports/mem0-history.sqlite").path
        env["ABOUT_TIME_MEM0_QDRANT_PATH"] = baseDirectory
            .appendingPathComponent("reports/mem0-qdrant").path
        env["ABOUT_TIME_OPENROUTER_BASE_URL"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"] ?? "https://openrouter.ai/api/v1"
        if let key = normalized(settings.openRouterAPIKey) {
            env["ABOUT_TIME_OPENROUTER_API_KEY"] = key
            env["OPENROUTER_API_KEY"] = key
            env["OPENAI_API_KEY"] = key
        }
        if let model = normalized(env["ABOUT_TIME_OPENROUTER_MODEL"]) {
            env["ABOUT_TIME_MEM0_LLM_MODEL"] = model
        }
        env["OPENAI_BASE_URL"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"]
        env["OPENAI_API_BASE"] = env["ABOUT_TIME_OPENROUTER_BASE_URL"]
        env["ABOUT_TIME_MEM0_EMBED_MODEL"] = env["ABOUT_TIME_MEM0_EMBED_MODEL"] ?? "openai/text-embedding-3-small"
        process.environment = env

        let input: [String: Any] = [
            "query": query,
            "start": start.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "end": end.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "limit": max(1, min(100, limit))
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            logger.error("Mem0 search launch failed: \(error.localizedDescription)")
            return []
        }

        if let data = try? JSONSerialization.data(withJSONObject: input, options: []) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        let outputText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if !errorText.isEmpty {
                logger.error("Mem0 search failed: \(errorText)")
            }
            return []
        }

        guard let payloadData = outputText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: payloadData, options: []),
              let object = raw as? [String: Any],
              (object["status"] as? String) == "ok",
              let hits = object["hits"] as? [[String: Any]]
        else {
            return []
        }

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

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
