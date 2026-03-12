import Foundation
import AppKit
import UniformTypeIdentifiers

struct DashboardSnapshot: Sendable {
    let day: Date
    let rows: [DashboardHourRow]
    let hourSummaries: [HourSummary]
    let usageToday: LLMUsageTotals
    let usageAllTime: LLMUsageTotals
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func get() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func update(_ newSettings: AppSettings) {
        lock.lock()
        settings = newSettings
        lock.unlock()
    }
}

final class TrackerRuntime: @unchecked Sendable {
    let config: TrackerConfig

    private let settingsBox: SettingsBox
    private let database: SQLiteStore
    private let logger: RuntimeLog
    private let trackerAgent: TrackerAgent
    private let memoryQueryService: MemoryQueryService
    private let calendar: Calendar

    private let stateLock = NSLock()
    private var transcriptStartedAt: Date?

    var onRecordingStateChanged: ((Bool) -> Void)?
    var onTranscriptStateChanged: ((Bool, Date?) -> Void)?

    private var iconCache: [String: NSImage] = [:]

    init(config: TrackerConfig = .fromEnvironment()) throws {
        self.config = config

        try FileManager.default.createDirectory(at: config.baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.screenshotsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings = AppSettingsStore.load(baseDirectory: config.baseDirectory, env: config.environment)
        settingsBox = SettingsBox(settings: settings)

        logger = RuntimeLog(baseDirectory: config.baseDirectory)
        database = try SQLiteStore(databaseURL: config.databaseURL)

        let mem0Ingestor = Mem0Ingestor(
            scriptURL: config.mem0ScriptURL,
            baseDirectory: config.baseDirectory,
            logger: logger
        )
        let mem0Searcher = Mem0Searcher(
            scriptURL: config.mem0SearchScriptURL,
            baseDirectory: config.baseDirectory,
            logger: logger
        )

        let retryJournal = RetryJournal(url: config.retryJournalURL)
        let screenshotCapture = try ScreenshotCapture(config: config)
        let audioCoordinator = try AudioCaptureCoordinator(
            outputDirectory: config.audioDirectory,
            chunkSeconds: config.audioChunkSeconds,
            logger: logger
        )

        let settingsProvider: @Sendable () -> AppSettings = { [settingsBox] in
            settingsBox.get()
        }
        let apiKeyProvider: @Sendable () -> String? = { [settingsBox, config] in
            AppSettingsStore.resolvedOpenRouterKey(settings: settingsBox.get(), env: config.environment)
        }

        let hourlyReporter = HourlyActivityReporter(
            config: config,
            database: database,
            logger: logger,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            mem0Ingestor: mem0Ingestor
        )

        trackerAgent = TrackerAgent(
            config: config,
            database: database,
            logger: logger,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            screenshotCapture: screenshotCapture,
            audioCoordinator: audioCoordinator,
            retryJournal: retryJournal,
            hourlyReporter: hourlyReporter
        )

        memoryQueryService = MemoryQueryService(
            database: database,
            mem0Searcher: mem0Searcher,
            settingsProvider: settingsProvider,
            apiKeyProvider: apiKeyProvider,
            openRouterConfig: config.openRouter
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        self.calendar = calendar

        trackerAgent.onRecordingStateChanged = { [weak self] running in
            self?.onRecordingStateChanged?(running)
        }
        trackerAgent.onTranscriptStateChanged = { [weak self] running, startedAt in
            guard let self else { return }
            self.stateLock.lock()
            self.transcriptStartedAt = startedAt
            self.stateLock.unlock()
            self.onTranscriptStateChanged?(running, startedAt)
        }
    }

    var isRecording: Bool {
        trackerAgent.isRecording()
    }

    var isTranscriptRunning: Bool {
        trackerAgent.isTranscriptRunning()
    }

    var currentTranscriptStartedAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return transcriptStartedAt
    }

    func startRecording() {
        trackerAgent.start()
    }

    func stopRecording(finalizePendingWork: Bool = true) {
        trackerAgent.stop(finalizePendingWork: finalizePendingWork)
    }

    func startTranscript() {
        trackerAgent.startTranscript()
    }

    func stopTranscript() {
        trackerAgent.stopTranscript()
    }

    func startupMessages() -> [String] {
        let settings = settingsBox.get()
        return [
            "data directory: \(config.baseDirectory.path)",
            "database: \(config.databaseURL.path)",
            "retry journal: \(config.retryJournalURL.path)",
            "screenshots: activation=\(Int(config.screenshotActivationDelaySeconds))s active=\(Int(config.screenshotWhileActiveSeconds))s",
            "audio transcript chunking: \(Int(config.audioChunkSeconds))s manual controls only",
            "openrouter endpoint: \(config.openRouter.endpoint.absoluteString)",
            "openrouter model: \(config.openRouter.model) reasoning=\(config.openRouter.reasoningEffort)",
            "mem0 enabled: \(settings.mem0Enabled) ingest_script=\(config.mem0ScriptURL.path)",
            "mem0 search script: \(config.mem0SearchScriptURL.path)",
            "track self-app: \(settings.includeSelfAppInTracking)"
        ]
    }

    func loadSettings() -> AppSettings {
        settingsBox.get()
    }

    func saveSettings(_ settings: AppSettings) throws {
        try AppSettingsStore.save(settings, baseDirectory: config.baseDirectory)
        settingsBox.update(settings)
    }

    func fetchDashboard(day: Date) async throws -> DashboardSnapshot {
        let intervals = try await database.listIntervals(forDay: day, calendar: calendar)
        let hourSummaries = try await database.listHourSummaries(day: day, calendar: calendar)
        let usageToday = try await database.usageTotals(day: day, calendar: calendar)
        let usageAll = try await database.usageTotals(day: nil, calendar: calendar)
        let rows = makeHourRows(intervals: intervals, day: day)

        return DashboardSnapshot(
            day: day,
            rows: rows,
            hourSummaries: hourSummaries,
            usageToday: usageToday,
            usageAllTime: usageAll
        )
    }

    func evidenceDetails(hourStart: Date, hourEnd: Date, appName: String, bundleID: String?) async throws -> [EvidenceDetailItem] {
        try await database.evidenceDetails(
            forHourStart: hourStart,
            hourEnd: hourEnd,
            appName: appName,
            bundleID: bundleID
        )
    }

    func runMemoryQuery(_ query: String, format: MemoryQueryOutputFormat = .text) async -> String {
        await memoryQueryService.render(
            request: MemoryQueryRequest(
                question: query,
                outputFormat: format
            )
        )
    }

    func dayUsageTotal(day: Date) async throws -> TimeInterval {
        let intervals = try await database.listIntervals(forDay: day, calendar: calendar)
        return intervals.reduce(0) { $0 + $1.duration }
    }

    private func makeHourRows(intervals: [ActivityInterval], day: Date) -> [DashboardHourRow] {
        let dayStart = calendar.startOfDay(for: day)

        var rows: [DashboardHourRow] = []

        for hour in 0..<24 {
            guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
            let hourEnd = hourStart.addingTimeInterval(3600)

            var grouped: [String: DashboardHourAppBlock] = [:]

            for interval in intervals {
                let start = max(hourStart, interval.startTime)
                let end = min(hourEnd, interval.endTime)
                guard end > start else { continue }

                let key = interval.app.bundleID ?? interval.app.appName
                let duration = end.timeIntervalSince(start)
                if var existing = grouped[key] {
                    existing = DashboardHourAppBlock(
                        id: existing.id,
                        hourStart: existing.hourStart,
                        hourEnd: existing.hourEnd,
                        appName: existing.appName,
                        bundleID: existing.bundleID,
                        duration: existing.duration + duration,
                        icon: existing.icon
                    )
                    grouped[key] = existing
                } else {
                    let blockID = "\(Int(hourStart.timeIntervalSince1970))::\(key)"
                    grouped[key] = DashboardHourAppBlock(
                        id: blockID,
                        hourStart: hourStart,
                        hourEnd: hourEnd,
                        appName: interval.app.appName,
                        bundleID: interval.app.bundleID,
                        duration: duration,
                        icon: appIcon(appName: interval.app.appName, bundleID: interval.app.bundleID)
                    )
                }
            }

            let blocks = grouped.values.sorted { lhs, rhs in
                if abs(lhs.duration - rhs.duration) > 0.1 {
                    return lhs.duration > rhs.duration
                }
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }

            rows.append(DashboardHourRow(id: hour, hour: hour, blocks: blocks))
        }

        return rows
    }

    private func appIcon(appName: String, bundleID: String?) -> NSImage? {
        let key = bundleID ?? appName
        if let cached = iconCache[key] {
            return cached
        }

        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            iconCache[key] = icon
            return icon
        }

        let fallback = NSWorkspace.shared.icon(for: .application)
        fallback.size = NSSize(width: 16, height: 16)
        iconCache[key] = fallback
        return fallback
    }
}
