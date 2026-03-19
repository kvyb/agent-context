import Foundation

struct TimelineSlice: Sendable {
    let startTime: Date
    let endTime: Date
    let appName: String
    let bundleID: String?
    let project: String?
}

struct StoredEvidenceRecord: Sendable {
    let metadata: ArtifactMetadata
    let analysis: ArtifactAnalysis?
}

struct MemoryRecord: Sendable {
    let occurredAt: Date
    let scope: String
    let appName: String?
    let project: String?
    let summary: String
    let entities: [String]
}

struct PurgedArtifactBatch: Sendable {
    let kind: ArtifactKind
    let deletedRows: Int
    let deletedPaths: [String]
}
