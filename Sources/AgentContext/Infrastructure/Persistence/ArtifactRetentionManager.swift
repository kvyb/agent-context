import Foundation

actor ArtifactRetentionManager {
    private let database: SQLiteStore
    private let logger: RuntimeLog
    private let fileManager = FileManager.default
    private let batchSize = 500

    init(database: SQLiteStore, logger: RuntimeLog) {
        self.database = database
        self.logger = logger
    }

    func runSweep(settings: AppSettings, reason: String) async {
        let screenshotStats = await purge(kind: .screenshot, ttlDays: settings.screenshotTTLDays)
        let audioStats = await purge(kind: .audio, ttlDays: settings.audioTTLDays)

        let deletedRows = screenshotStats.rowsDeleted + audioStats.rowsDeleted
        let deletedFiles = screenshotStats.filesDeleted + audioStats.filesDeleted
        guard deletedRows > 0 || deletedFiles > 0 else { return }

        logger.info(
            "Retention sweep (\(reason)) removed \(deletedRows) DB rows / \(deletedFiles) files " +
            "[screenshots rows=\(screenshotStats.rowsDeleted) files=\(screenshotStats.filesDeleted), " +
            "audio rows=\(audioStats.rowsDeleted) files=\(audioStats.filesDeleted)]"
        )
    }

    private func purge(kind: ArtifactKind, ttlDays: Int) async -> RetentionSweepStats {
        guard ttlDays > 0 else { return RetentionSweepStats() }

        let cutoff = Date().addingTimeInterval(-TimeInterval(ttlDays) * 86_400)
        var totals = RetentionSweepStats()

        while true {
            let batch: PurgedArtifactBatch
            do {
                batch = try await database.purgeEvidence(
                    kind: kind,
                    capturedBefore: cutoff,
                    limit: batchSize
                )
            } catch {
                logger.error("Retention purge failed for \(kind.rawValue): \(error.localizedDescription)")
                break
            }

            guard batch.deletedRows > 0 else { break }
            totals.rowsDeleted += batch.deletedRows
            totals.filesDeleted += removeFiles(atPaths: batch.deletedPaths)
        }

        return totals
    }

    private func removeFiles(atPaths paths: [String]) -> Int {
        var deleted = 0
        for path in paths {
            guard !path.isEmpty else { continue }
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.removeItem(atPath: path)
                deleted += 1
            } catch {
                logger.error("Failed to remove retained artifact \(path): \(error.localizedDescription)")
            }
        }
        return deleted
    }
}

private struct RetentionSweepStats {
    var rowsDeleted: Int = 0
    var filesDeleted: Int = 0
}
