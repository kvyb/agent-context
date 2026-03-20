import Foundation

enum SQLiteBM25Heuristics {
    static let interviewMarkers = ["interview", "candidate", "metaview", "notetaker", "zoom"]
    static let metaNoiseIndicators = ["telegram reminder", "analyze the transcript later", "remind me", "follow up later", "todo", "later analysis"]
}

enum LexicalRetrievalUnit: String {
    case taskSegment = "task_segment"
    case transcriptUnit = "transcript_unit"
    case transcriptChunk = "transcript_chunk"
    case artifactEvidence = "artifact_evidence"
    case memorySummary = "memory_summary"
}

struct ArtifactCandidate {
    let id: String
    let appName: String?
    let project: String?
    let occurredAt: Date?
    let document: String
    let summary: String
    let metadata: [String: String]
    let baseScore: Double
}
