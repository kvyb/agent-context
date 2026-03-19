import Foundation

struct AppSettings: Codable, Sendable {
    var openRouterAPIKey: String?
    // Multimodal model used for screenshot/video-style evidence extraction.
    var openRouterModel: String
    // Audio-capable model used for transcript chunk analysis.
    var openRouterAudioModel: String
    // Text model used for synthesis, planning, and memory answers.
    var openRouterTextModel: String
    var captureScreenshots: Bool
    var screenshotTTLDays: Int
    var audioTTLDays: Int
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

    static let defaultOpenRouterModel = "google/gemini-3.1-flash-lite-preview"
    static let defaultArtifactTTLDays = 3

    static let `default` = AppSettings(
        openRouterAPIKey: nil,
        openRouterModel: AppSettings.defaultOpenRouterModel,
        openRouterAudioModel: AppSettings.defaultOpenRouterModel,
        openRouterTextModel: AppSettings.defaultOpenRouterModel,
        captureScreenshots: true,
        screenshotTTLDays: AppSettings.defaultArtifactTTLDays,
        audioTTLDays: AppSettings.defaultArtifactTTLDays,
        transcriptControlsEnabled: true,
        requireTranscriptConsent: true,
        includeSelfAppInTracking: false,
        userIdentityAliases: [],
        mem0Enabled: true,
        mem0UserID: "agent-context-user",
        mem0AgentID: "agent-context-tracker",
        mem0Collection: "agent_context_memories",
        openRouterAppNameHeader: "Agent Context",
        openRouterRefererHeader: nil
    )

    init(
        openRouterAPIKey: String?,
        openRouterModel: String,
        openRouterAudioModel: String,
        openRouterTextModel: String,
        captureScreenshots: Bool,
        screenshotTTLDays: Int,
        audioTTLDays: Int,
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
        self.openRouterModel = AppSettings.normalizedOpenRouterModel(openRouterModel)
        self.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(openRouterAudioModel)
        self.openRouterTextModel = AppSettings.normalizedOpenRouterModel(openRouterTextModel)
        self.captureScreenshots = captureScreenshots
        self.screenshotTTLDays = AppSettings.normalizedTTLDays(screenshotTTLDays)
        self.audioTTLDays = AppSettings.normalizedTTLDays(audioTTLDays)
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
        case openRouterModel
        case openRouterAudioModel
        case openRouterTextModel
        case captureScreenshots
        case screenshotTTLDays
        case audioTTLDays
        case transcriptControlsEnabled
        case requireTranscriptConsent
        case includeSelfAppInTracking
        case userIdentityAliases
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
        let legacyOrDefaultModel = AppSettings.normalizedOpenRouterModel(
            try container.decodeIfPresent(String.self, forKey: .openRouterModel)
            ?? defaults.openRouterModel
        )
        openRouterModel = legacyOrDefaultModel
        openRouterAudioModel = AppSettings.normalizedOpenRouterModel(
            try container.decodeIfPresent(String.self, forKey: .openRouterAudioModel)
            ?? legacyOrDefaultModel
        )
        openRouterTextModel = AppSettings.normalizedOpenRouterModel(
            try container.decodeIfPresent(String.self, forKey: .openRouterTextModel)
            ?? legacyOrDefaultModel
        )
        captureScreenshots = try container.decodeIfPresent(Bool.self, forKey: .captureScreenshots) ?? defaults.captureScreenshots
        screenshotTTLDays = AppSettings.normalizedTTLDays(
            try container.decodeIfPresent(Int.self, forKey: .screenshotTTLDays) ?? defaults.screenshotTTLDays
        )
        audioTTLDays = AppSettings.normalizedTTLDays(
            try container.decodeIfPresent(Int.self, forKey: .audioTTLDays) ?? defaults.audioTTLDays
        )
        transcriptControlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcriptControlsEnabled) ?? defaults.transcriptControlsEnabled
        requireTranscriptConsent = try container.decodeIfPresent(Bool.self, forKey: .requireTranscriptConsent) ?? defaults.requireTranscriptConsent
        includeSelfAppInTracking = try container.decodeIfPresent(Bool.self, forKey: .includeSelfAppInTracking)
            ?? defaults.includeSelfAppInTracking
        userIdentityAliases = AppSettings.normalizedAliases(
            try container.decodeIfPresent([String].self, forKey: .userIdentityAliases)
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
        try container.encode(AppSettings.normalizedOpenRouterModel(openRouterModel), forKey: .openRouterModel)
        try container.encode(AppSettings.normalizedOpenRouterModel(openRouterAudioModel), forKey: .openRouterAudioModel)
        try container.encode(AppSettings.normalizedOpenRouterModel(openRouterTextModel), forKey: .openRouterTextModel)
        try container.encode(captureScreenshots, forKey: .captureScreenshots)
        try container.encode(AppSettings.normalizedTTLDays(screenshotTTLDays), forKey: .screenshotTTLDays)
        try container.encode(AppSettings.normalizedTTLDays(audioTTLDays), forKey: .audioTTLDays)
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

    static func normalizedOpenRouterModel(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultOpenRouterModel
    }

    static func normalizedTTLDays(_ value: Int?) -> Int {
        let raw = value ?? defaultArtifactTTLDays
        return min(3650, max(0, raw))
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
            if let envKey = normalized(env["OPENROUTER_API_KEY"] ?? env["AGENT_CONTEXT_OPENROUTER_API_KEY"]) {
                defaults.openRouterAPIKey = envKey
            }
            let envDefaultModel = AppSettings.normalizedOpenRouterModel(env["AGENT_CONTEXT_OPENROUTER_MODEL"])
            defaults.openRouterModel = AppSettings.normalizedOpenRouterModel(
                env["AGENT_CONTEXT_OPENROUTER_MULTIMODAL_MODEL"] ?? envDefaultModel
            )
            defaults.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(
                env["AGENT_CONTEXT_OPENROUTER_AUDIO_MODEL"] ?? envDefaultModel
            )
            defaults.openRouterTextModel = AppSettings.normalizedOpenRouterModel(
                env["AGENT_CONTEXT_OPENROUTER_TEXT_MODEL"] ?? envDefaultModel
            )
            defaults.screenshotTTLDays = AppSettings.normalizedTTLDays(
                env["AGENT_CONTEXT_SCREENSHOT_TTL_DAYS"].flatMap(Int.init)
            )
            defaults.audioTTLDays = AppSettings.normalizedTTLDays(
                env["AGENT_CONTEXT_AUDIO_TTL_DAYS"].flatMap(Int.init)
            )
            defaults.userIdentityAliases = AppSettings.parseAliases(from: env["AGENT_CONTEXT_USER_ALIASES"])
            return defaults
        }

        var settings = decoded
        if settings.openRouterAPIKey?.isEmpty != false {
            settings.openRouterAPIKey = normalized(env["OPENROUTER_API_KEY"] ?? env["AGENT_CONTEXT_OPENROUTER_API_KEY"])
        }
        let envDefaultModel = AppSettings.normalizedOpenRouterModel(env["AGENT_CONTEXT_OPENROUTER_MODEL"])
        settings.openRouterModel = AppSettings.normalizedOpenRouterModel(
            settings.openRouterModel.nilIfEmpty
            ?? env["AGENT_CONTEXT_OPENROUTER_MULTIMODAL_MODEL"]
            ?? envDefaultModel
        )
        settings.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(
            settings.openRouterAudioModel.nilIfEmpty
            ?? env["AGENT_CONTEXT_OPENROUTER_AUDIO_MODEL"]
            ?? settings.openRouterModel
        )
        settings.openRouterTextModel = AppSettings.normalizedOpenRouterModel(
            settings.openRouterTextModel.nilIfEmpty
            ?? env["AGENT_CONTEXT_OPENROUTER_TEXT_MODEL"]
            ?? settings.openRouterModel
        )
        settings.screenshotTTLDays = AppSettings.normalizedTTLDays(settings.screenshotTTLDays)
        settings.audioTTLDays = AppSettings.normalizedTTLDays(settings.audioTTLDays)
        settings.userIdentityAliases = AppSettings.normalizedAliases(settings.userIdentityAliases)
        if settings.userIdentityAliases.isEmpty {
            settings.userIdentityAliases = AppSettings.parseAliases(from: env["AGENT_CONTEXT_USER_ALIASES"])
        }
        return settings
    }

    static func save(_ settings: AppSettings, baseDirectory: URL) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = settingsURL(baseDirectory: baseDirectory)

        var settingsToPersist = settings
        settingsToPersist.openRouterAPIKey = normalized(settings.openRouterAPIKey)
        settingsToPersist.openRouterModel = AppSettings.normalizedOpenRouterModel(settings.openRouterModel)
        settingsToPersist.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(settings.openRouterAudioModel)
        settingsToPersist.openRouterTextModel = AppSettings.normalizedOpenRouterModel(settings.openRouterTextModel)
        settingsToPersist.screenshotTTLDays = AppSettings.normalizedTTLDays(settings.screenshotTTLDays)
        settingsToPersist.audioTTLDays = AppSettings.normalizedTTLDays(settings.audioTTLDays)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settingsToPersist)
        try data.write(to: url, options: .atomic)
    }

    static func resolvedOpenRouterKey(settings: AppSettings, env: [String: String]) -> String? {
        normalized(settings.openRouterAPIKey)
            ?? normalized(env["OPENROUTER_API_KEY"] ?? env["AGENT_CONTEXT_OPENROUTER_API_KEY"])
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
