import Foundation

struct AppSettings: Codable, Sendable {
    var openRouterAPIKey: String?
    var captureScreenshots: Bool
    var transcriptControlsEnabled: Bool
    var requireTranscriptConsent: Bool
    var includeAboutTimeAppInTracking: Bool
    var mem0Enabled: Bool
    var mem0UserID: String
    var mem0AgentID: String
    var mem0Collection: String
    var openRouterAppNameHeader: String?
    var openRouterRefererHeader: String?

    static let `default` = AppSettings(
        openRouterAPIKey: nil,
        captureScreenshots: true,
        transcriptControlsEnabled: true,
        requireTranscriptConsent: true,
        includeAboutTimeAppInTracking: false,
        mem0Enabled: true,
        mem0UserID: "about-time-user",
        mem0AgentID: "about-time-tracker",
        mem0Collection: "about_time_memories",
        openRouterAppNameHeader: "About Time",
        openRouterRefererHeader: nil
    )
}

enum AppSettingsStore {
    private static let fileName = "settings.json"

    static func settingsURL(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(fileName)
    }

    static func load(baseDirectory: URL, env: [String: String]) -> AppSettings {
        let url = settingsURL(baseDirectory: baseDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? decoder.decode(AppSettings.self, from: data)
        else {
            var defaults = AppSettings.default
            if let envKey = normalized(env["OPENROUTER_API_KEY"] ?? env["ABOUT_TIME_OPENROUTER_API_KEY"]) {
                defaults.openRouterAPIKey = envKey
            }
            return defaults
        }

        var settings = decoded
        if settings.openRouterAPIKey?.isEmpty != false {
            settings.openRouterAPIKey = normalized(env["OPENROUTER_API_KEY"] ?? env["ABOUT_TIME_OPENROUTER_API_KEY"])
        }
        return settings
    }

    static func save(_ settings: AppSettings, baseDirectory: URL) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = settingsURL(baseDirectory: baseDirectory)

        var settingsToPersist = settings
        settingsToPersist.openRouterAPIKey = normalized(settings.openRouterAPIKey)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settingsToPersist)
        try data.write(to: url, options: .atomic)
    }

    static func resolvedOpenRouterKey(settings: AppSettings, env: [String: String]) -> String? {
        normalized(settings.openRouterAPIKey)
            ?? normalized(env["OPENROUTER_API_KEY"] ?? env["ABOUT_TIME_OPENROUTER_API_KEY"])
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
