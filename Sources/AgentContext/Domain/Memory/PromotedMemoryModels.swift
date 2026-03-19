import Foundation

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

enum PromotedSourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case artifactPerception = "artifact_perception"
    case transcriptUnit = "transcript_unit"
    case intervalSummary = "interval_summary"
    case hourSummary = "hour_summary"
}

struct TaskSegmentDraft: Codable, Sendable {
    let task: String
    let issueOrGoal: String?
    let actions: [String]
    let outcome: String?
    let nextStep: String?
    let people: [String]
    let blocker: String?
    let status: TaskSegmentStatus
    let confidence: Double
    let evidenceRefs: [String]
    let evidenceExcerpts: [String]
    let entities: [String]
    let project: String?
    let workspace: String?
    let repo: String?
    let document: String?
    let url: String?
    let appName: String?
    let bundleID: String?
    let artifactKinds: [ArtifactKind]
    let sourceKinds: [PromotedSourceKind]

    init(
        task: String,
        issueOrGoal: String? = nil,
        actions: [String] = [],
        outcome: String? = nil,
        nextStep: String? = nil,
        people: [String] = [],
        blocker: String? = nil,
        status: TaskSegmentStatus = .unknown,
        confidence: Double = 0,
        evidenceRefs: [String] = [],
        evidenceExcerpts: [String] = [],
        entities: [String] = [],
        project: String? = nil,
        workspace: String? = nil,
        repo: String? = nil,
        document: String? = nil,
        url: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        artifactKinds: [ArtifactKind] = [],
        sourceKinds: [PromotedSourceKind] = []
    ) {
        self.task = task
        self.issueOrGoal = issueOrGoal
        self.actions = actions
        self.outcome = outcome
        self.nextStep = nextStep
        self.people = people
        self.blocker = blocker
        self.status = status
        self.confidence = confidence
        self.evidenceRefs = evidenceRefs
        self.evidenceExcerpts = evidenceExcerpts
        self.entities = entities
        self.project = project
        self.workspace = workspace
        self.repo = repo
        self.document = document
        self.url = url
        self.appName = appName
        self.bundleID = bundleID
        self.artifactKinds = artifactKinds
        self.sourceKinds = sourceKinds
    }
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
    let people: [String]
    let blocker: String?
    let status: TaskSegmentStatus
    let confidence: Double
    let evidenceRefs: [String]
    let evidenceExcerpts: [String]
    let entities: [String]
    let artifactKinds: [ArtifactKind]
    let sourceKinds: [PromotedSourceKind]
    let summary: String
    let sourceSummaryID: String?
    let promptVersion: String

    init(
        id: String,
        scope: String,
        startTime: Date,
        endTime: Date,
        occurredAt: Date,
        appName: String? = nil,
        bundleID: String? = nil,
        project: String? = nil,
        workspace: String? = nil,
        repo: String? = nil,
        document: String? = nil,
        url: String? = nil,
        task: String,
        issueOrGoal: String? = nil,
        actions: [String] = [],
        outcome: String? = nil,
        nextStep: String? = nil,
        people: [String] = [],
        blocker: String? = nil,
        status: TaskSegmentStatus = .unknown,
        confidence: Double = 0,
        evidenceRefs: [String] = [],
        evidenceExcerpts: [String] = [],
        entities: [String] = [],
        artifactKinds: [ArtifactKind] = [],
        sourceKinds: [PromotedSourceKind] = [],
        summary: String,
        sourceSummaryID: String? = nil,
        promptVersion: String
    ) {
        self.id = id
        self.scope = scope
        self.startTime = startTime
        self.endTime = endTime
        self.occurredAt = occurredAt
        self.appName = appName
        self.bundleID = bundleID
        self.project = project
        self.workspace = workspace
        self.repo = repo
        self.document = document
        self.url = url
        self.task = task
        self.issueOrGoal = issueOrGoal
        self.actions = actions
        self.outcome = outcome
        self.nextStep = nextStep
        self.people = people
        self.blocker = blocker
        self.status = status
        self.confidence = confidence
        self.evidenceRefs = evidenceRefs
        self.evidenceExcerpts = evidenceExcerpts
        self.entities = entities
        self.artifactKinds = artifactKinds
        self.sourceKinds = sourceKinds
        self.summary = summary
        self.sourceSummaryID = sourceSummaryID
        self.promptVersion = promptVersion
    }
}

enum TranscriptUnitKind: String, Codable, Sendable, CaseIterable {
    case speakerExchange = "speaker_exchange"
    case transcriptExcerpt = "transcript_excerpt"
}

struct TranscriptUnitRecord: Codable, Sendable, Identifiable {
    let id: String
    let evidenceID: String
    let occurredAt: Date
    let appName: String?
    let bundleID: String?
    let project: String?
    let workspace: String?
    let task: String?
    let sessionID: String?
    let kind: TranscriptUnitKind
    let speakerLabel: String?
    let summary: String
    let excerptText: String
    let topicTags: [String]
    let people: [String]
    let entities: [String]
    let sourceEvidenceRefs: [String]
    let sourceExcerpts: [String]
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
