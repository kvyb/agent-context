import Foundation

struct MemoryQueryEvidenceFormatter: Sendable {
    func formatLine(_ hit: MemoryEvidenceHit) -> String {
        let iso = ISO8601DateFormatter()
        let timestamp = hit.occurredAt.map { iso.string(from: $0) } ?? "unknown-time"
        let app = hit.appName?.nilIfEmpty ?? "unknown-app"
        let project = hit.project?.nilIfEmpty ?? hit.metadata["project"]?.nilIfEmpty ?? ""
        let projectSuffix = project.isEmpty ? "" : " | project=\(project)"
        let retrievalUnit = hit.metadata["retrieval_unit"]?.nilIfEmpty ?? "memory"
        let unitSuffix = " | unit=\(retrievalUnit)"
        let taskSuffix = hit.metadata["task"]?.nilIfEmpty.map { " | task=\($0)" } ?? ""
        let statusSuffix = hit.metadata["task_segment_status"]?.nilIfEmpty.map { " | status=\($0)" } ?? ""
        let workspaceSuffix = hit.metadata["workspace"]?.nilIfEmpty.map { " | workspace=\($0)" } ?? ""
        let repoSuffix = hit.metadata["repo"]?.nilIfEmpty.map { " | repo=\($0)" } ?? ""
        let titleSuffix = hit.metadata["window_title"]?.nilIfEmpty.map { " | title=\($0)" } ?? ""
        let score: Double = hit.source == .mem0Semantic ? hit.semanticScore : hit.lexicalScore
        return "[\(timestamp)] source=\(hit.source.rawValue) score=\(String(format: "%.2f", score)) app=\(app)\(projectSuffix)\(unitSuffix)\(taskSuffix)\(statusSuffix)\(workspaceSuffix)\(repoSuffix)\(titleSuffix) | memory=\(hit.text)"
    }
}
