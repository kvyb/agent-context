import Foundation

func runtimeEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for candidate in dotEnvCandidates() {
        guard let values = loadDotEnv(candidate) else { continue }
        for (key, value) in values where env[key] == nil {
            env[key] = value
        }
    }
    return env
}

private func dotEnvCandidates() -> [URL] {
    let fileManager = FileManager.default
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    let home = fileManager.homeDirectoryForCurrentUser
    var candidates = [
        cwd.appendingPathComponent(".env"),
        home.appendingPathComponent(".agent-context/.env")
    ]

    if let resourceURL = Bundle.main.resourceURL {
        candidates.append(resourceURL.appendingPathComponent(".env"))
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

func loadDotEnv(_ url: URL) -> [String: String]? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }

    var values: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
        var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }

        if line.hasPrefix("export ") {
            line.removeFirst("export ".count)
            line = line.trimmingCharacters(in: .whitespaces)
        }

        guard let equal = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }

        var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
            value = value.replacingOccurrences(of: "\\n", with: "\n")
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
            value = value.replacingOccurrences(of: "\\'", with: "'")
        }

        values[key] = value
    }

    return values
}

func parseBool(_ raw: String?, defaultValue: Bool) -> Bool {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
        return defaultValue
    }

    switch value {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}
