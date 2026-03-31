import XCTest
@testable import AgentContext

final class MemoryQueryEvidenceSelectionTests: XCTestCase {
    func testPrioritizedSubsetDiversifiesBroadWorkSummaryEvidence() {
        let analysis = MemoryQueryQuestionAnalysis(
            focusTerms: [],
            personTerms: [],
            requestedDimensions: [],
            mentionsZoom: false,
            seeksEvaluation: false,
            seeksWorkSummary: true,
            seeksCallConversation: false,
            prefersLexicalFirst: false,
            prefersDetailedAnswer: true
        )
        let scope = MemoryQueryScope(
            start: date("2026-03-23T00:00:00Z"),
            end: date("2026-03-30T00:00:00Z"),
            label: "last week"
        )
        let evidence = [
            hit(id: "a1", app: "Codex", project: "playbox", timestamp: "2026-03-23T10:00:00Z"),
            hit(id: "a2", app: "Codex", project: "playbox", timestamp: "2026-03-23T10:30:00Z"),
            hit(id: "a3", app: "Codex", project: "playbox", timestamp: "2026-03-23T11:00:00Z"),
            hit(id: "a4", app: "Codex", project: "playbox", timestamp: "2026-03-23T11:30:00Z"),
            hit(id: "b1", app: "Zoom", project: "farmington", timestamp: "2026-03-24T09:00:00Z"),
            hit(id: "c1", app: "Orion", project: "research", timestamp: "2026-03-25T14:00:00Z"),
            hit(id: "d1", app: "Slack", project: "ops", timestamp: "2026-03-26T08:00:00Z"),
            hit(id: "e1", app: "Telegram", project: "chat", timestamp: "2026-03-27T16:00:00Z")
        ]

        let selected = MemoryQueryEvidenceSelection.prioritizedSubset(
            from: evidence,
            limit: 4,
            detailLevel: .detailed,
            analysis: analysis,
            scope: scope
        )

        XCTAssertEqual(selected.count, 4)
        XCTAssertGreaterThanOrEqual(Set(selected.compactMap(\.appName)).count, 3)
        XCTAssertGreaterThanOrEqual(Set(selected.compactMap { dayString($0.occurredAt) }).count, 3)
        XCTAssertTrue(selected.contains { $0.id == "b1" })
        XCTAssertTrue(selected.contains { $0.id == "c1" || $0.id == "d1" || $0.id == "e1" })
    }

    func testPrioritizedSubsetPreservesOrderForNonSummaryQueries() {
        let analysis = MemoryQueryQuestionAnalysis(
            focusTerms: ["agent-context"],
            personTerms: [],
            requestedDimensions: [],
            mentionsZoom: false,
            seeksEvaluation: false,
            seeksWorkSummary: false,
            seeksCallConversation: false,
            prefersLexicalFirst: false,
            prefersDetailedAnswer: true
        )
        let evidence = [
            hit(id: "x1", app: "Codex", project: "agent-context", timestamp: "2026-03-25T18:30:00Z"),
            hit(id: "x2", app: "Telegram", project: "agent-context", timestamp: "2026-03-23T22:00:00Z"),
            hit(id: "x3", app: "Google Chrome", project: "playbox", timestamp: "2026-03-27T22:56:00Z")
        ]

        let selected = MemoryQueryEvidenceSelection.prioritizedSubset(
            from: evidence,
            limit: 2,
            detailLevel: .detailed,
            analysis: analysis,
            scope: nil
        )

        XCTAssertEqual(selected.map(\.id), ["x1", "x2"])
    }

    func testPrioritizedSubsetDiversifiesAcrossRetrievalUnitsForBroadSummaries() {
        let analysis = MemoryQueryQuestionAnalysis(
            focusTerms: [],
            personTerms: [],
            requestedDimensions: [],
            mentionsZoom: false,
            seeksEvaluation: false,
            seeksWorkSummary: true,
            seeksCallConversation: false,
            prefersLexicalFirst: false,
            prefersDetailedAnswer: true
        )
        let scope = MemoryQueryScope(
            start: date("2026-03-23T00:00:00Z"),
            end: date("2026-03-30T00:00:00Z"),
            label: "last week"
        )
        let evidence = [
            hit(id: "t1", app: "Codex", project: "playbox", timestamp: "2026-03-23T10:00:00Z", unit: "task_segment"),
            hit(id: "t2", app: "Codex", project: "playbox", timestamp: "2026-03-23T10:30:00Z", unit: "task_segment"),
            hit(id: "a1", app: "Finder", project: "playbox", timestamp: "2026-03-24T09:00:00Z", unit: "artifact_evidence"),
            hit(id: "h1", app: "Slack", project: "ops", timestamp: "2026-03-25T08:00:00Z", unit: "hour_summary"),
            hit(id: "tr1", app: "Zoom", project: "farmington", timestamp: "2026-03-26T11:00:00Z", unit: "transcript_chunk")
        ]

        let selected = MemoryQueryEvidenceSelection.prioritizedSubset(
            from: evidence,
            limit: 4,
            detailLevel: .detailed,
            analysis: analysis,
            scope: scope
        )

        XCTAssertGreaterThanOrEqual(Set(selected.compactMap { $0.metadata["retrieval_unit"] }).count, 3)
    }

    private func hit(id: String, app: String, project: String, timestamp: String, unit: String = "task_segment") -> MemoryEvidenceHit {
        MemoryEvidenceHit(
            id: id,
            source: .mem0Semantic,
            text: "\(app) \(project) \(timestamp)",
            appName: app,
            project: project,
            occurredAt: date(timestamp),
            metadata: ["retrieval_unit": unit],
            semanticScore: 0,
            lexicalScore: 0.9,
            hybridScore: 0.9
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    private func dayString(_ value: Date?) -> String {
        guard let value else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
