import Foundation

struct AppSettings: Codable, Sendable {
    var openRouterAPIKey: String?
    var captureScreenshots: Bool
    var transcriptControlsEnabled: Bool
    var requireTranscriptConsent: Bool
    var includeSelfAppInTracking: Bool
    var userIdentityAliases: [String]
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
        includeSelfAppInTracking: false,
        userIdentityAliases: [],
        mem0Enabled: true,
        mem0UserID: "about-time-user",
        mem0AgentID: "about-time-tracker",
        mem0Collection: "about_time_memories",
        openRouterAppNameHeader: "Agent Context",
        openRouterRefererHeader: nil
    )

    init(
        openRouterAPIKey: String?,
        captureScreenshots: Bool,
        transcriptControlsEnabled: Bool,
        requireTranscriptConsent: Bool,
        includeSelfAppInTracking: Bool,
        userIdentityAliases: [String],
        mem0Enabled: Bool,
        mem0UserID: String,
        mem0AgentID: String,
        mem0Collection: String,
        openRouterAppNameHeader: String?,
        openRouterRefererHeader: String?
    ) {
        self.openRouterAPIKey = openRouterAPIKey
        self.captureScreenshots = captureScreenshots
        self.transcriptControlsEnabled = transcriptControlsEnabled
        self.requireTranscriptConsent = requireTranscriptConsent
        self.includeSelfAppInTracking = includeSelfAppInTracking
        self.userIdentityAliases = AppSettings.normalizedAliases(userIdentityAliases)
        self.mem0Enabled = mem0Enabled
        self.mem0UserID = mem0UserID
        self.mem0AgentID = mem0AgentID
        self.mem0Collection = mem0Collection
        self.openRouterAppNameHeader = openRouterAppNameHeader
        self.openRouterRefererHeader = openRouterRefererHeader
    }

    private enum CodingKeys: String, CodingKey {
        case openRouterAPIKey
        case captureScreenshots
        case transcriptControlsEnabled
        case requireTranscriptConsent
        case includeSelfAppInTracking
        case includeAboutTimeAppInTracking
        case userIdentityAliases
        case userAliases
        case mem0Enabled
        case mem0UserID
        case mem0AgentID
        case mem0Collection
        case openRouterAppNameHeader
        case openRouterRefererHeader
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        openRouterAPIKey = try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey)
        captureScreenshots = try container.decodeIfPresent(Bool.self, forKey: .captureScreenshots) ?? defaults.captureScreenshots
        transcriptControlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcriptControlsEnabled) ?? defaults.transcriptControlsEnabled
        requireTranscriptConsent = try container.decodeIfPresent(Bool.self, forKey: .requireTranscriptConsent) ?? defaults.requireTranscriptConsent
        includeSelfAppInTracking = try container.decodeIfPresent(Bool.self, forKey: .includeSelfAppInTracking)
            ?? container.decodeIfPresent(Bool.self, forKey: .includeAboutTimeAppInTracking)
            ?? defaults.includeSelfAppInTracking
        userIdentityAliases = AppSettings.normalizedAliases(
            try container.decodeIfPresent([String].self, forKey: .userIdentityAliases)
            ?? container.decodeIfPresent([String].self, forKey: .userAliases)
            ?? defaults.userIdentityAliases
        )
        mem0Enabled = try container.decodeIfPresent(Bool.self, forKey: .mem0Enabled) ?? defaults.mem0Enabled
        mem0UserID = try container.decodeIfPresent(String.self, forKey: .mem0UserID) ?? defaults.mem0UserID
        mem0AgentID = try container.decodeIfPresent(String.self, forKey: .mem0AgentID) ?? defaults.mem0AgentID
        mem0Collection = try container.decodeIfPresent(String.self, forKey: .mem0Collection) ?? defaults.mem0Collection
        openRouterAppNameHeader = try container.decodeIfPresent(String.self, forKey: .openRouterAppNameHeader) ?? defaults.openRouterAppNameHeader
        openRouterRefererHeader = try container.decodeIfPresent(String.self, forKey: .openRouterRefererHeader) ?? defaults.openRouterRefererHeader
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(openRouterAPIKey, forKey: .openRouterAPIKey)
        try container.encode(captureScreenshots, forKey: .captureScreenshots)
        try container.encode(transcriptControlsEnabled, forKey: .transcriptControlsEnabled)
        try container.encode(requireTranscriptConsent, forKey: .requireTranscriptConsent)
        try container.encode(includeSelfAppInTracking, forKey: .includeSelfAppInTracking)
        try container.encode(AppSettings.normalizedAliases(userIdentityAliases), forKey: .userIdentityAliases)
        try container.encode(mem0Enabled, forKey: .mem0Enabled)
        try container.encode(mem0UserID, forKey: .mem0UserID)
        try container.encode(mem0AgentID, forKey: .mem0AgentID)
        try container.encode(mem0Collection, forKey: .mem0Collection)
        try container.encodeIfPresent(openRouterAppNameHeader, forKey: .openRouterAppNameHeader)
        try container.encodeIfPresent(openRouterRefererHeader, forKey: .openRouterRefererHeader)
    }

    static func parseAliases(from raw: String?) -> [String] {
        guard let raw = raw?.nilIfEmpty else { return [] }
        return normalizedAliases(
            raw.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    static func aliasesText(_ aliases: [String]) -> String {
        normalizedAliases(aliases).joined(separator: ", ")
    }

    static func normalizedAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for alias in aliases {
            guard let normalized = alias.nilIfEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(normalized)
        }
        return output
    }
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
            defaults.userIdentityAliases = AppSettings.parseAliases(from: env["ABOUT_TIME_USER_ALIASES"])
            return defaults
        }

        var settings = decoded
        if settings.openRouterAPIKey?.isEmpty != false {
            settings.openRouterAPIKey = normalized(env["OPENROUTER_API_KEY"] ?? env["ABOUT_TIME_OPENROUTER_API_KEY"])
        }
        settings.userIdentityAliases = AppSettings.normalizedAliases(settings.userIdentityAliases)
        if settings.userIdentityAliases.isEmpty {
            settings.userIdentityAliases = AppSettings.parseAliases(from: env["ABOUT_TIME_USER_ALIASES"])
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
