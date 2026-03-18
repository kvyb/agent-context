import XCTest
@testable import AgentContext

final class SQLiteBM25MemoryRetrieverTests: XCTestCase {
    func testTranscriptLikeQueriesSurfaceAudioEvidenceFromAnchorWindow() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let parser = MemoryQueryScopeParser(calendar: utcCalendar)
        let retriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: BM25Ranker(),
            scopeParser: parser
        )

        let intervalStart = date(year: 2026, month: 3, day: 16, hour: 21, minute: 0)
        let intervalEnd = date(year: 2026, month: 3, day: 16, hour: 21, minute: 10)
        try await database.saveTaskSegments([
            TaskSegmentRecord(
                id: "segment-1",
                scope: "interval",
                startTime: intervalStart,
                endTime: intervalEnd,
                occurredAt: intervalStart,
                appName: "zoom.us",
                bundleID: "us.zoom.xos",
                project: "AI Core Team",
                workspace: "zoom.us",
                repo: nil,
                document: nil,
                url: nil,
                task: "Conduct technical interview for Machine Learning Engineer role",
                issueOrGoal: "Evaluate the candidate",
                actions: ["Asked about GraphRAG", "Discussed evaluation metrics"],
                outcome: "Interview in progress",
                nextStep: "Summarize fit",
                status: .inProgress,
                confidence: 1,
                evidenceRefs: [],
                entities: ["Mikhail Baranov", "Metaview", "Zoom"],
                summary: "Task: Conduct technical interview for Machine Learning Engineer role",
                sourceSummaryID: nil,
                promptVersion: "test"
            )
        ])

        try await insertEvidence(
            database: database,
            id: "audio-1",
            appName: "Codex",
            capturedAt: date(year: 2026, month: 3, day: 16, hour: 21, minute: 4),
            kind: .audio,
            title: "Technical Interview",
            analysis: ArtifactAnalysis(
                description: "Candidate described a GraphRAG system for company report generation.",
                summary: "Topics: GraphRAG, parser-based ingestion, vector storage.",
                transcript: "S1: We built a parser for company documents, stored them in a vector database, and used GraphRAG when standard retrieval missed business relationships.",
                entities: ["GraphRAG", "vector database", "Mikhail Baranov"],
                insufficientEvidence: false,
                project: "AI Core Team",
                workspace: "zoom.us",
                task: "Candidate interview",
                evidence: []
            )
        )

        try await insertEvidence(
            database: database,
            id: "audio-2",
            appName: "zoom.us",
            capturedAt: date(year: 2026, month: 3, day: 16, hour: 21, minute: 22),
            kind: .audio,
            title: "Technical Interview",
            analysis: ArtifactAnalysis(
                description: "Candidate explained ranking metrics for retrieval.",
                summary: "Topics: NDCG, LLM-based evaluation, retrieval metrics.",
                transcript: "S1: For retrieval quality we start with ranking metrics like NDCG and then add LLM-based evaluation for the end-to-end RAG system.",
                entities: ["NDCG", "retrieval", "Mikhail Baranov"],
                insufficientEvidence: false,
                project: "AI Core Team",
                workspace: "zoom.us",
                task: "Candidate interview",
                evidence: []
            )
        )

        let scope = MemoryQueryScope(
            start: date(year: 2026, month: 3, day: 16, hour: 18),
            end: date(year: 2026, month: 3, day: 17, hour: 6),
            label: "last night"
        )

        let hits = await retriever.retrieve(
            queries: ["How well does the candidate from the zoom interview last night match an intermediate level based on the transcript?"],
            scope: scope,
            limit: 6
        )

        XCTAssertTrue(hits.contains { $0.id == "evidence|audio-1" })
        XCTAssertTrue(hits.contains { $0.id == "evidence|audio-2" })
        XCTAssertEqual(hits.first?.metadata["artifact_kind"], ArtifactKind.audio.rawValue)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(
            calendar: utcCalendar,
            timeZone: utcCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func insertEvidence(
        database: SQLiteStore,
        id: String,
        appName: String,
        capturedAt: Date,
        kind: ArtifactKind,
        title: String,
        analysis: ArtifactAnalysis
    ) async throws {
        let metadata = ArtifactMetadata(
            id: id,
            kind: kind,
            path: "/tmp/\(id)",
            capturedAt: capturedAt,
            app: AppDescriptor(appName: appName, bundleID: nil, pid: 42),
            window: WindowContext(title: title, documentPath: nil, url: nil, workspace: appName, project: "AI Core Team"),
            intervalID: "interval-1",
            captureReason: "test",
            sequenceInInterval: 0
        )

        try await database.insertEvidence(metadata)
        try await database.markEvidenceAnalyzed(
            evidenceID: id,
            analysis: analysis,
            usage: nil,
            model: "test-model"
        )
    }
}
