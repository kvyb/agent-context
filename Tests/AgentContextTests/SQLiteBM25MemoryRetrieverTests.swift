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

        XCTAssertTrue(hits.contains { $0.id.hasPrefix("transcript-unit|audio-1-transcript-") })
        XCTAssertTrue(hits.contains { $0.id.hasPrefix("transcript-unit|audio-2-transcript-") })
        XCTAssertEqual(hits.first?.metadata["retrieval_unit"], "transcript_unit")
    }

    func testWorkSummaryQueriesPreferTaskSegmentsOverLooseMemorySummaries() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let parser = MemoryQueryScopeParser(calendar: utcCalendar)
        let retriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: BM25Ranker(),
            scopeParser: parser
        )

        let dayStart = date(year: 2026, month: 3, day: 16, hour: 9)
        let dayEnd = date(year: 2026, month: 3, day: 16, hour: 18)
        try await database.saveTaskSegments([
            TaskSegmentRecord(
                id: "manychat-task",
                scope: "day",
                startTime: dayStart,
                endTime: dayEnd,
                occurredAt: dayStart,
                appName: "GitHub",
                bundleID: "com.github",
                project: "ManyChat",
                workspace: "/tmp/manychat",
                repo: "manychat/backend",
                document: nil,
                url: nil,
                task: "Reviewed sampler PR and debugged ManyChat rate-limit workflow",
                issueOrGoal: "Stabilize sampler rollout",
                actions: ["Reviewed PR 568", "Investigated rate-limit retries"],
                outcome: "Identified rollback risk and follow-up actions",
                nextStep: "Coordinate rollout changes with AI Research",
                status: .inProgress,
                confidence: 0.98,
                evidenceRefs: [],
                entities: ["ManyChat", "PR 568", "sampler"],
                summary: "Task: Reviewed sampler PR and debugged ManyChat rate-limit workflow",
                sourceSummaryID: nil,
                promptVersion: "test"
            )
        ])

        try await database.saveMemoryPayload(
            MemoryPayload(
                id: "mem0-open-tulpa",
                scope: "task_segment",
                occurredAt: dayStart,
                appName: "Codex",
                project: "OpenTulpa",
                summary: "Worked on OpenTulpa terminal timeout debugging and tunnel startup.",
                entities: ["OpenTulpa", "timeout"],
                metadata: [:]
            ),
            status: "ok",
            responseJSON: nil
        )

        let hits = await retriever.retrieve(
            queries: ["What did user do for ManyChat on 2026-03-16? What are the projects, tasks, and struggles?"],
            scope: MemoryQueryScope(start: dayStart, end: dayEnd, label: "2026-03-16"),
            limit: 5
        )

        XCTAssertEqual(hits.first?.project, "ManyChat")
        XCTAssertEqual(hits.first?.metadata["retrieval_unit"], "task_segment")
    }

    func testTranscriptLikeQueriesPreferSpeakerExchangeWindows() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let parser = MemoryQueryScopeParser(calendar: utcCalendar)
        let retriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: BM25Ranker(),
            scopeParser: parser
        )

        let capturedAt = date(year: 2026, month: 3, day: 16, hour: 21, minute: 15)
        try await insertEvidence(
            database: database,
            id: "audio-exchange",
            appName: "zoom.us",
            capturedAt: capturedAt,
            kind: .audio,
            title: "Technical Interview",
            analysis: ArtifactAnalysis(
                description: "Candidate explained how retrieval quality was measured.",
                summary: "Topics: retrieval metrics and evaluation.",
                transcript: "S2: How did you evaluate retrieval quality in production? S1: We started with NDCG and then validated the end-to-end answer quality with LLM-as-a-judge checks.",
                entities: ["NDCG", "evaluation", "candidate"],
                insufficientEvidence: false,
                project: "AI Core Team",
                workspace: "zoom.us",
                task: "Candidate interview",
                evidence: []
            )
        )

        let hits = await retriever.retrieve(
            queries: ["What did the candidate say about evaluation metrics in the interview transcript?"],
            scope: MemoryQueryScope(
                start: date(year: 2026, month: 3, day: 16, hour: 18),
                end: date(year: 2026, month: 3, day: 17, hour: 6),
                label: "on 2026-03-16"
            ),
            limit: 3
        )

        XCTAssertEqual(hits.first?.metadata["retrieval_unit"], "transcript_unit")
        XCTAssertEqual(hits.first?.metadata["speaker_exchange"], "true")
        XCTAssertTrue(hits.first?.text.contains("S2: How did you evaluate retrieval quality") == true)
        XCTAssertTrue(hits.first?.text.contains("S1: We started with NDCG") == true)
    }

    func testCallConversationQueriesPreferDirectZoomEvidenceOverRelatedTaskWork() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let parser = MemoryQueryScopeParser(calendar: utcCalendar)
        let retriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: BM25Ranker(),
            scopeParser: parser
        )

        let dayStart = date(year: 2026, month: 3, day: 20, hour: 14, minute: 0)
        let dayEnd = date(year: 2026, month: 3, day: 20, hour: 16, minute: 0)

        try await insertEvidence(
            database: database,
            id: "zoom-call-audio",
            appName: "Codex",
            capturedAt: date(year: 2026, month: 3, day: 20, hour: 14, minute: 47),
            kind: .audio,
            title: "Zoom call",
            analysis: ArtifactAnalysis(
                description: "Discussed background agent jobs and pipeline integration.",
                summary: "Topics: BullMQ, asynchronous agent jobs, pipeline integration.",
                transcript: "S1: What do you think about the integration? S2: We can run the agent in the background with BullMQ and sync on Monday. Toly asked about timing.",
                entities: ["Toly Sherbakov", "BullMQ", "agent", "pipeline"],
                insufficientEvidence: false,
                project: "AI Service",
                workspace: "zoom.us",
                task: "Zoom call about agents",
                evidence: ["BullMQ background jobs", "Monday sync"]
            )
        )

        try await insertEvidence(
            database: database,
            id: "telegram-audio",
            appName: "Telegram",
            capturedAt: date(year: 2026, month: 3, day: 20, hour: 14, minute: 49),
            kind: .audio,
            title: "Telegram voice note",
            analysis: ArtifactAnalysis(
                description: "Toly discussed lead qualification presets and video-screen agent integration in a Telegram follow-up.",
                summary: "Topics: lead qualification, templates, presets, video screens.",
                transcript: "S1: Toly said we should keep working on the presets and video screens next week for the sales qualification flow.",
                entities: ["Toly Sherbakov", "sales qualification", "video screens", "presets"],
                insufficientEvidence: false,
                project: "AI Service",
                workspace: "Telegram",
                task: "Telegram follow-up",
                evidence: ["presets", "video screens"]
            )
        )

        try await database.saveTaskSegments([
            TaskSegmentRecord(
                id: "related-task",
                scope: "day",
                startTime: dayStart,
                endTime: dayEnd,
                occurredAt: date(year: 2026, month: 3, day: 20, hour: 14, minute: 30),
                appName: "Notion",
                bundleID: "notion.id",
                project: "Manychat AI Lead Qualification",
                workspace: "Notion",
                repo: nil,
                document: nil,
                url: nil,
                task: "Review PRD for Lead Qualification Skill/Agent",
                issueOrGoal: "Review lead qualification flowchart",
                actions: ["Reviewed concept", "Discussed sales qualification"],
                outcome: "Concept clarified",
                nextStep: "Follow up later",
                status: .inProgress,
                confidence: 1,
                evidenceRefs: [],
                entities: ["lead qualification", "sales qualification", "agent"],
                summary: "Review PRD for Lead Qualification Skill/Agent",
                sourceSummaryID: nil,
                promptVersion: "test"
            )
        ])

        let hits = await retriever.retrieve(
            queries: ["what did we talk about on the zoom call with Toly about regarding pipelines and AI agents?"],
            scope: MemoryQueryScope(start: dayStart, end: dayEnd, label: "today"),
            limit: 5
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy {
            let unit = $0.metadata["retrieval_unit"]
            return unit == "transcript_unit" || unit == "transcript_chunk" || unit == "artifact_evidence"
        })
        XCTAssertTrue(hits.contains { $0.id.hasPrefix("transcript-unit|zoom-call-audio-transcript-") })
        XCTAssertFalse(hits.contains { $0.id.hasPrefix("transcript-unit|telegram-audio-transcript-") })
        XCTAssertFalse(hits.contains { $0.id == "task-segment|related-task" })
    }

    func testBroadCallHistoryQueriesCanSurfaceZoomTaskSummaries() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let parser = MemoryQueryScopeParser(calendar: utcCalendar)
        let retriever = SQLiteBM25MemoryRetriever(
            database: database,
            ranker: BM25Ranker(),
            scopeParser: parser
        )

        let dayStart = date(year: 2026, month: 3, day: 23, hour: 9, minute: 0)
        let dayEnd = date(year: 2026, month: 3, day: 23, hour: 18, minute: 0)

        try await database.saveTaskSegments([
            TaskSegmentRecord(
                id: "zoom-grooming",
                scope: "day",
                startTime: date(year: 2026, month: 3, day: 23, hour: 17, minute: 0),
                endTime: date(year: 2026, month: 3, day: 23, hour: 18, minute: 0),
                occurredAt: date(year: 2026, month: 3, day: 23, hour: 17, minute: 40),
                appName: "zoom.us",
                bundleID: "us.zoom.xos",
                project: "AI features",
                workspace: "zoom.us",
                repo: nil,
                document: nil,
                url: nil,
                task: "Attend AI features weekly grooming meeting",
                issueOrGoal: "Discuss implementation requirements for AI features",
                actions: ["Reviewed labeling and draft mode"],
                outcome: "Implementation direction agreed",
                nextStep: "Implement labeling and Draft Mode functionality",
                status: .done,
                confidence: 1,
                evidenceRefs: [],
                entities: ["AI features", "Zoom"],
                summary: "Attend AI features weekly grooming meeting",
                sourceSummaryID: nil,
                promptVersion: "test"
            )
        ])

        let hits = await retriever.retrieve(
            queries: ["What calls did I have today?", "zoom meeting"],
            scope: MemoryQueryScope(start: dayStart, end: dayEnd, label: "today"),
            limit: 5,
            contextQuestion: "What calls did I have today?"
        )

        XCTAssertTrue(hits.contains { $0.id == "task-segment|zoom-grooming" })
        XCTAssertTrue(hits.contains { $0.metadata["retrieval_unit"] == LexicalRetrievalUnit.taskSegment.rawValue })
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
