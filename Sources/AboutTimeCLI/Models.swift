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
    let summary: String
    let transcript: String?
    let entities: [String]
    let insufficientEvidence: Bool
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case summary
        case transcript
        case entities
        case insufficientEvidence
        case project
        case workspace
        case task
        case evidence
    }

    init(
        summary: String,
        transcript: String?,
        entities: [String],
        insufficientEvidence: Bool,
        project: String? = nil,
        workspace: String? = nil,
        task: String? = nil,
        evidence: [String] = []
    ) {
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
        summary = try container.decode(String.self, forKey: .summary)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        entities = try container.decodeIfPresent([String].self, forKey: .entities) ?? []
        insufficientEvidence = try container.decodeIfPresent(Bool.self, forKey: .insufficientEvidence) ?? false
        project = try container.decodeIfPresent(String.self, forKey: .project)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
    }
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
