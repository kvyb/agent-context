import XCTest
@testable import AgentContext

final class SQLiteStoreMem0AssetBackfillTests: XCTestCase {
    func testAnalyzedEvidenceMissingAssetPayloadsExcludeAlreadyQueuedAssets() async throws {
        let database = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let capturedAt = date(year: 2026, month: 3, day: 31, hour: 10, minute: 15)
        let metadata = ArtifactMetadata(
            id: "asset-1",
            kind: .screenshot,
            path: "/tmp/asset-1.png",
            capturedAt: capturedAt,
            app: AppDescriptor(appName: "Warp", bundleID: "dev.warp.Warp-Stable", pid: 42),
            window: WindowContext(
                title: "agent-context",
                documentPath: "/tmp/repo",
                url: "https://github.com/example/repo",
                workspace: "Warp",
                project: "Agent Context"
            ),
            intervalID: "interval-1",
            captureReason: "active",
            sequenceInInterval: 1
        )

        try await database.insertEvidence(metadata)
        try await database.markEvidenceAnalyzed(
            evidenceID: metadata.id,
            analysis: ArtifactAnalysis(
                description: "Reviewing asset-analysis persistence changes in agent-context.",
                summary: "Working on Mem0 asset persistence.",
                transcript: nil,
                entities: ["agent-context", "Mem0"],
                insufficientEvidence: false,
                project: "Agent Context",
                workspace: "Warp",
                task: "Persist asset analysis in Mem0",
                evidence: ["Terminal output references mem0 queue rows."]
            ),
            usage: nil,
            model: "test-model"
        )

        let before = try await database.listAnalyzedEvidenceMissingMem0AssetPayloads(limit: 10)
        XCTAssertEqual(before.map(\.metadata.id), ["asset-1"])

        try await database.saveMemoryPayload(
            MemoryPayload(
                id: "asset-asset-1",
                scope: "asset_analysis",
                occurredAt: capturedAt,
                appName: "Warp",
                project: "Agent Context",
                summary: "Asset kind: screenshot | Summary: Working on Mem0 asset persistence.",
                entities: ["agent-context", "Mem0"],
                metadata: ["artifact_kind": "screenshot"]
            ),
            status: "pending",
            responseJSON: nil
        )

        let after = try await database.listAnalyzedEvidenceMissingMem0AssetPayloads(limit: 10)
        XCTAssertTrue(after.isEmpty)
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
}
