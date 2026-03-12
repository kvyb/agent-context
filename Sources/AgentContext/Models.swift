import Foundation
import AppKit

enum ArtifactKind: String, Codable {
    case screenshot
    case audio
}

struct WindowContext: Codable, Sendable {
    let title: String?
    let documentPath: String?
    let url: String?
    let workspace: String?
    let project: String?
}

struct AppDescriptor: Codable, Sendable, Hashable {
    let appName: String
    let bundleID: String?
    let pid: Int32
}

struct ActivityInterval: Codable, Sendable, Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date
    let app: AppDescriptor
    let window: WindowContext

    var duration: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }

    var appKey: String {
        if let bundleID = app.bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return app.appName
    }
}

struct ArtifactMetadata: Codable, Sendable {
    let id: String
    let kind: ArtifactKind
    let path: String
    let capturedAt: Date
    let app: AppDescriptor
    let window: WindowContext
    let intervalID: String?
    let captureReason: String
    let sequenceInInterval: Int
}

struct ArtifactAnalysis: Codable, Sendable {
    let description: String
    let problem: String?
    let success: String?
    let userContribution: String?
    let suggestionOrDecision: String?
    let status: ArtifactInferenceStatus
    let confidence: Double
    let summary: String
    let transcript: String?
    let entities: [String]
    let insufficientEvidence: Bool
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case description
        case problem
        case success
        case userContribution
        case userContributionSnake = "user_contribution"
        case suggestionOrDecision
        case suggestionOrDecisionSnake = "suggestion_or_decision"
        case status
        case confidence
        case summary
        case transcript
        case entities
        case insufficientEvidence
        case insufficientEvidenceSnake = "insufficient_evidence"
        case project
        case workspace
        case task
        case evidence
    }

    init(
        description: String,
        problem: String? = nil,
        success: String? = nil,
        userContribution: String? = nil,
        suggestionOrDecision: String? = nil,
        status: ArtifactInferenceStatus = .none,
        confidence: Double = 0,
        summary: String,
        transcript: String?,
        entities: [String],
        insufficientEvidence: Bool,
        project: String? = nil,
        workspace: String? = nil,
        task: String? = nil,
        evidence: [String] = []
    ) {
        self.description = description
        self.problem = problem
        self.success = success
        self.userContribution = userContribution
        self.suggestionOrDecision = suggestionOrDecision
        self.status = status
        self.confidence = max(0, min(1, confidence))
        self.summary = summary
        self.transcript = transcript
        self.entities = entities
        self.insufficientEvidence = insufficientEvidence
        self.project = project
        self.workspace = workspace
        self.task = task
        self.evidence = evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSummary = try container.decodeIfPresent(String.self, forKey: .summary)
        let decodedDescription = try container.decodeIfPresent(String.self, forKey: .description)
        description = decodedDescription?.nilIfEmpty ?? decodedSummary?.nilIfEmpty ?? "insufficient evidence"
        summary = decodedSummary?.nilIfEmpty ?? description
        problem = try container.decodeIfPresent(String.self, forKey: .problem)?.nilIfEmpty
        success = try container.decodeIfPresent(String.self, forKey: .success)?.nilIfEmpty
        let decodedUserContribution = try container.decodeIfPresent(String.self, forKey: .userContribution)?.nilIfEmpty
        let decodedUserContributionSnake = try container.decodeIfPresent(String.self, forKey: .userContributionSnake)?.nilIfEmpty
        userContribution = decodedUserContribution ?? decodedUserContributionSnake

        let decodedSuggestionOrDecision = try container.decodeIfPresent(String.self, forKey: .suggestionOrDecision)?.nilIfEmpty
        let decodedSuggestionOrDecisionSnake = try container.decodeIfPresent(String.self, forKey: .suggestionOrDecisionSnake)?.nilIfEmpty
        suggestionOrDecision = decodedSuggestionOrDecision ?? decodedSuggestionOrDecisionSnake

        if let statusRaw = try container.decodeIfPresent(String.self, forKey: .status)?.nilIfEmpty {
            let normalizedStatus = statusRaw.lowercased()
            switch normalizedStatus {
            case "in_progress", "in progress", "active", "working":
                status = .inProgress
            case "blocked", "stalled":
                status = .blocked
            case "resolved", "done", "completed":
                status = .resolved
            default:
                status = ArtifactInferenceStatus(rawValue: normalizedStatus) ?? .none
            }
        } else {
            status = .none
        }
        confidence = max(0, min(1, try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0))
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        entities = try container.decodeIfPresent([String].self, forKey: .entities) ?? []
        let decodedInsufficientEvidence = try container.decodeIfPresent(Bool.self, forKey: .insufficientEvidence)
        let decodedInsufficientEvidenceSnake = try container.decodeIfPresent(Bool.self, forKey: .insufficientEvidenceSnake)
        insufficientEvidence = decodedInsufficientEvidence ?? decodedInsufficientEvidenceSnake ?? false
        project = try container.decodeIfPresent(String.self, forKey: .project)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(problem, forKey: .problem)
        try container.encodeIfPresent(success, forKey: .success)
        try container.encodeIfPresent(userContribution, forKey: .userContribution)
        try container.encodeIfPresent(suggestionOrDecision, forKey: .suggestionOrDecision)
        try container.encode(status, forKey: .status)
        try container.encode(max(0, min(1, confidence)), forKey: .confidence)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(entities, forKey: .entities)
        try container.encode(insufficientEvidence, forKey: .insufficientEvidence)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encodeIfPresent(task, forKey: .task)
        try container.encode(evidence, forKey: .evidence)
    }
}

enum ArtifactInferenceStatus: String, Codable, Sendable, CaseIterable {
    case none
    case blocked
    case inProgress = "in_progress"
    case resolved
}

struct IntervalSummary: Codable, Sendable, Identifiable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let appName: String
    let bundleID: String?
    let summary: String
    let entities: [String]
    let insufficientEvidence: Bool
}

struct HourSummary: Codable, Sendable, Identifiable {
    let id: String
    let hourStart: Date
    let hourEnd: Date
    let summary: String
}

struct LLMUsageEvent: Codable, Sendable {
    let id: String
    let kind: String
    let createdAt: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let audioTokens: Int
    let estimatedCostUSD: Double
}

struct LLMUsageTotals: Codable, Sendable {
    var requestCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var audioTokens: Int = 0
    var estimatedCostUSD: Double = 0

    mutating func add(_ event: LLMUsageEvent) {
        requestCount += 1
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        audioTokens += event.audioTokens
        estimatedCostUSD += event.estimatedCostUSD
    }
}

struct RetryArtifactItem: Codable, Sendable, Identifiable {
    let id: String
    let metadata: ArtifactMetadata
    var attempts: Int
    var nextAttemptAt: Date
    var lastError: String?
    var failedPermanently: Bool
}

struct MemoryPayload: Codable, Sendable {
    let id: String
    let scope: String
    let occurredAt: Date
    let appName: String?
    let project: String?
    let summary: String
    let entities: [String]
    let metadata: [String: String]
}

enum TaskSegmentStatus: String, Codable, Sendable, CaseIterable {
    case done
    case pending
    case inProgress = "in_progress"
    case blocked
    case unknown

    var isPendingLike: Bool {
        switch self {
        case .pending, .inProgress, .blocked, .unknown:
            return true
        case .done:
            return false
        }
    }
}

struct TaskSegmentDraft: Codable, Sendable {
    let task: String
    let issueOrGoal: String?
    let actions: [String]
    let outcome: String?
    let nextStep: String?
    let status: TaskSegmentStatus
    let confidence: Double
    let evidenceRefs: [String]
    let entities: [String]
    let project: String?
    let workspace: String?
    let repo: String?
    let document: String?
    let url: String?
    let appName: String?
    let bundleID: String?
}

struct StructuredSynthesis: Sendable {
    let summary: String
    let entities: [String]
    let insufficientEvidence: Bool
    let taskSegments: [TaskSegmentDraft]
}

struct TaskSegmentRecord: Codable, Sendable, Identifiable {
    let id: String
    let scope: String
    let startTime: Date
    let endTime: Date
    let occurredAt: Date
    let appName: String?
    let bundleID: String?
    let project: String?
    let workspace: String?
    let repo: String?
    let document: String?
    let url: String?
    let task: String
    let issueOrGoal: String?
    let actions: [String]
    let outcome: String?
    let nextStep: String?
    let status: TaskSegmentStatus
    let confidence: Double
    let evidenceRefs: [String]
    let entities: [String]
    let summary: String
    let sourceSummaryID: String?
    let promptVersion: String
}

struct PendingIntervalBucketItem: Sendable {
    let bucketStart: Date
    let attempts: Int
}

struct PendingHourItem: Sendable {
    let hourStart: Date
    let attempts: Int
}

struct PendingMem0Item: Sendable {
    let payload: MemoryPayload
    let status: String
}

struct Mem0SearchHit: Sendable {
    let score: Double?
    let memory: String
    let appName: String?
    let project: String?
    let occurredAt: Date?
    let metadata: [String: String]
}

struct DashboardHourRow: Identifiable, Sendable {
    let id: Int
    let hour: Int
    let blocks: [DashboardHourAppBlock]
}

struct DashboardHourAppBlock: Identifiable, Sendable {
    let id: String
    let hourStart: Date
    let hourEnd: Date
    let appName: String
    let bundleID: String?
    let duration: TimeInterval
    let icon: NSImage?
}

struct DashboardDayAppRow: Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleID: String?
    let duration: TimeInterval
    let icon: NSImage?
}

struct DashboardHourUsage: Identifiable, Sendable {
    let id: Int
    let hour: Int
    let duration: TimeInterval
}

struct DashboardWeekdayUsage: Identifiable, Sendable {
    let id: String
    let day: Date
    let duration: TimeInterval
}

struct EvidenceDetailItem: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let kind: ArtifactKind
    let appName: String
    let description: String
    let problem: String?
    let success: String?
    let userContribution: String?
    let suggestionOrDecision: String?
    let status: ArtifactInferenceStatus
    let confidence: Double
    let summary: String
    let transcript: String?
    let entities: [String]
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]
}

extension Calendar {
    func floorToTenMinute(_ date: Date) -> Date {
        var components = dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = ((components.minute ?? 0) / 10) * 10
        components.second = 0
        return self.date(from: components) ?? date
    }

    func hourStart(for date: Date) -> Date {
        dateInterval(of: .hour, for: date)?.start ?? date
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
