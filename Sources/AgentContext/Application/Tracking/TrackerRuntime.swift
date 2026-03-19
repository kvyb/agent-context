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

enum AppUpdateRelationship: String, Sendable {
    case upToDate
    case behind
    case ahead
    case diverged
}

struct AppUpdateStatus: Sendable {
    let repositoryURL: URL
    let branch: String
    let localCommit: String
    let remoteCommit: String
    let relationship: AppUpdateRelationship
    let isWorkingTreeDirty: Bool
}

struct AppUpdateRunResult: Sendable {
    let status: AppUpdateStatus
    let didRestart: Bool
    let message: String
}

enum AppUpdateError: LocalizedError {
    case repositoryNotFound
    case workingTreeDirty
    case unsupportedBranch(String)
    case diverged
    case commandFailed(command: String, details: String)
    case restartLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotFound:
            return "Repository root was not found. Set AGENT_CONTEXT_REPO_ROOT in ~/.agent-context/.env or reinstall via scripts/install.sh."
        case .workingTreeDirty:
            return "Update cancelled because the repository has uncommitted changes."
        case let .unsupportedBranch(branch):
            return "Update requires local branch main (current: \(branch))."
        case .diverged:
            return "Local branch has diverged from origin/main. Resolve manually before running update."
        case let .commandFailed(command, details):
            if details.isEmpty {
                return "Command failed: \(command)"
            }
            return "Command failed: \(command)\n\(details)"
        case let .restartLaunchFailed(details):
            return details
        }
    }
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
    private let retentionManager: ArtifactRetentionManager
    private let trackerAgent: TrackerAgent
    private let memoryQueryService: MemoryQueryService
    private let memoryQueryEvaluationService: MemoryQueryEvaluationService
    private let calendar: Calendar
    private let retentionQueue = DispatchQueue(label: "agent-context.retention", qos: .utility)
    private var retentionTimer: DispatchSourceTimer?

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
        retentionManager = ArtifactRetentionManager(database: database, logger: logger)

        let mem0Ingestor = Mem0Ingestor(
            pythonExecutableURL: config.pythonExecutableURL,
            scriptURL: config.mem0ScriptURL,
            baseDirectory: config.baseDirectory,
            logger: logger
        )
        let mem0Searcher = Mem0Searcher(
            pythonExecutableURL: config.pythonExecutableURL,
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
            openRouterConfig: config.openRouter,
            runtimeConfig: config.memoryQuery
        )
        memoryQueryEvaluationService = MemoryQueryEvaluationService(
            queryService: memoryQueryService,
            evaluator: OpenRouterMemoryQueryEvaluator(
                openRouterConfig: config.openRouter,
                settingsProvider: settingsProvider,
                apiKeyProvider: apiKeyProvider,
                codec: MemoryQueryEvaluationCodec()
            ),
            usageWriter: SQLiteUsageEventWriter(database: database)
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

        scheduleRetentionSweeps()
    }

    deinit {
        retentionTimer?.cancel()
        retentionTimer = nil
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
            "retention TTL days: screenshots=\(settings.screenshotTTLDays == 0 ? "forever" : "\(settings.screenshotTTLDays)") audio=\(settings.audioTTLDays == 0 ? "forever" : "\(settings.audioTTLDays)")",
            "openrouter endpoint: \(config.openRouter.endpoint.absoluteString)",
            "openrouter models: multimodal=\(settings.openRouterModel) audio=\(settings.openRouterAudioModel) text=\(settings.openRouterTextModel) reasoning=\(config.openRouter.reasoningEffort)",
            "mem0 enabled: \(settings.mem0Enabled) ingest_script=\(config.mem0ScriptURL.path)",
            "mem0 search script: \(config.mem0SearchScriptURL.path)",
            "python executable: \(config.pythonExecutableURL.path)",
            "track self-app: \(settings.includeSelfAppInTracking)"
        ]
    }

    func loadSettings() -> AppSettings {
        settingsBox.get()
    }

    func saveSettings(_ settings: AppSettings) throws {
        try AppSettingsStore.save(settings, baseDirectory: config.baseDirectory)
        settingsBox.update(settings)
        runRetentionSweep(reason: "settings-save")
    }

    func checkForUpdatesAgainstMain() throws -> AppUpdateStatus {
        let repositoryURL = try repositoryRootURL()
        if let scriptStatus = try checkWithUpdateScript(repositoryURL: repositoryURL) {
            return scriptStatus
        }
        return try checkForUpdatesUsingGit(repositoryURL: repositoryURL)
    }

    func updateFromMainRebuildAndRestart() throws -> AppUpdateRunResult {
        let repositoryURL = try repositoryRootURL()
        if let scriptResult = try applyWithUpdateScript(repositoryURL: repositoryURL) {
            if scriptResult.action == "updated" {
                try relaunchUpdatedApp(repositoryURL: repositoryURL)
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
                return AppUpdateRunResult(
                    status: scriptResult.status,
                    didRestart: true,
                    message: scriptResult.message ?? "Updated. Restarting Agent Context..."
                )
            }

            return AppUpdateRunResult(
                status: scriptResult.status,
                didRestart: false,
                message: scriptResult.message ?? updateStatusSummary(scriptResult.status)
            )
        }

        let preflight = try checkForUpdatesUsingGit(repositoryURL: repositoryURL)

        switch preflight.relationship {
        case .upToDate:
            return AppUpdateRunResult(
                status: preflight,
                didRestart: false,
                message: "Already up to date (\(shortCommit(preflight.localCommit)))."
            )
        case .ahead:
            return AppUpdateRunResult(
                status: preflight,
                didRestart: false,
                message: "Local checkout is already ahead of origin/main."
            )
        case .diverged:
            throw AppUpdateError.diverged
        case .behind:
            break
        }

        guard preflight.branch == "main" else {
            throw AppUpdateError.unsupportedBranch(preflight.branch)
        }
        guard !preflight.isWorkingTreeDirty else {
            throw AppUpdateError.workingTreeDirty
        }

        _ = try runGit(arguments: ["pull", "--ff-only", "origin", "main"], in: repositoryURL)
        try rebuildUpdatedApp(repositoryURL: repositoryURL)

        let postUpdateStatus = try checkForUpdatesUsingGit(repositoryURL: repositoryURL)
        try relaunchUpdatedApp(repositoryURL: repositoryURL)

        Task { @MainActor in
            NSApp.terminate(nil)
        }

        return AppUpdateRunResult(
            status: postUpdateStatus,
            didRestart: true,
            message: "Updated to \(shortCommit(postUpdateStatus.localCommit)). Restarting Agent Context..."
        )
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

    func runMemoryQuery(
        _ query: String,
        format: MemoryQueryOutputFormat = .text,
        options: MemoryQueryOptions = .default,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await memoryQueryService.render(
            request: MemoryQueryRequest(
                question: query,
                outputFormat: format,
                options: options,
                onProgress: onProgress
            )
        )
    }

    func evaluateMemoryQuery(
        _ query: String,
        format: MemoryQueryOutputFormat = .text,
        options: MemoryQueryOptions = .default,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        await memoryQueryEvaluationService.render(
            request: MemoryQueryRequest(
                question: query,
                outputFormat: format,
                options: options,
                onProgress: onProgress
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

    private func checkForUpdatesUsingGit(repositoryURL: URL) throws -> AppUpdateStatus {
        _ = try runGit(arguments: ["fetch", "--quiet", "origin", "main"], in: repositoryURL)

        let branch = try runGit(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], in: repositoryURL)
        let localCommit = try runGit(arguments: ["rev-parse", "HEAD"], in: repositoryURL)
        let remoteCommit = try runGit(arguments: ["rev-parse", "origin/main"], in: repositoryURL)
        let mergeBase = try runGit(arguments: ["merge-base", "HEAD", "origin/main"], in: repositoryURL)
        let statusOutput = try runGit(arguments: ["status", "--porcelain"], in: repositoryURL)

        let relationship: AppUpdateRelationship
        if localCommit == remoteCommit {
            relationship = .upToDate
        } else if localCommit == mergeBase {
            relationship = .behind
        } else if remoteCommit == mergeBase {
            relationship = .ahead
        } else {
            relationship = .diverged
        }

        return AppUpdateStatus(
            repositoryURL: repositoryURL,
            branch: branch,
            localCommit: localCommit,
            remoteCommit: remoteCommit,
            relationship: relationship,
            isWorkingTreeDirty: !statusOutput.isEmpty
        )
    }

    private func checkWithUpdateScript(repositoryURL: URL) throws -> AppUpdateStatus? {
        guard FileManager.default.fileExists(atPath: updateScriptURL(repositoryURL: repositoryURL).path) else {
            return nil
        }
        let result = try runUpdateScript(
            repositoryURL: repositoryURL,
            arguments: ["--status", "--repo", repositoryURL.path]
        )
        return result.status
    }

    private func applyWithUpdateScript(repositoryURL: URL) throws -> UpdateScriptResult? {
        guard FileManager.default.fileExists(atPath: updateScriptURL(repositoryURL: repositoryURL).path) else {
            return nil
        }

        var arguments = ["--apply", "--repo", repositoryURL.path, "--no-restart"]
        if let bundlePath = currentBundlePath() {
            arguments.append(contentsOf: ["--bundle", bundlePath])
        }
        return try runUpdateScript(repositoryURL: repositoryURL, arguments: arguments)
    }

    private func runUpdateScript(repositoryURL: URL, arguments: [String]) throws -> UpdateScriptResult {
        let scriptURL = updateScriptURL(repositoryURL: repositoryURL)
        let output = try runCommand(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path] + arguments,
            currentDirectoryURL: repositoryURL
        )

        if output.terminationStatus == 0 {
            return try parseUpdateScriptOutput(output.stdout, defaultRepositoryURL: repositoryURL)
        }

        if let parsed = try? parseUpdateScriptOutput(output.stdout, defaultRepositoryURL: repositoryURL),
           let message = parsed.message?.nilIfEmpty {
            throw AppUpdateError.commandFailed(
                command: "\(scriptURL.lastPathComponent) \(arguments.joined(separator: " "))",
                details: message
            )
        }

        throw AppUpdateError.commandFailed(
            command: "\(scriptURL.lastPathComponent) \(arguments.joined(separator: " "))",
            details: output.stderr.nilIfEmpty ?? output.stdout
        )
    }

    private func parseUpdateScriptOutput(_ output: String, defaultRepositoryURL: URL) throws -> UpdateScriptResult {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = value
        }

        guard
            let branch = values["branch"],
            let localCommit = values["local_commit"],
            let remoteCommit = values["remote_commit"]
        else {
            throw AppUpdateError.commandFailed(
                command: "update.sh parser",
                details: "Unexpected update script output."
            )
        }

        let repositoryPath = values["repo"] ?? defaultRepositoryURL.path
        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)

        let relationship = parseRelationship(values["relationship"] ?? "upToDate")
        let dirtyRaw = values["dirty"]?.lowercased() ?? "0"
        let isDirty = dirtyRaw == "1" || dirtyRaw == "true" || dirtyRaw == "yes"

        let status = AppUpdateStatus(
            repositoryURL: repositoryURL,
            branch: branch,
            localCommit: localCommit,
            remoteCommit: remoteCommit,
            relationship: relationship,
            isWorkingTreeDirty: isDirty
        )

        return UpdateScriptResult(
            status: status,
            action: values["action"] ?? "none",
            message: values["message"]?.nilIfEmpty
        )
    }

    private func updateScriptURL(repositoryURL: URL) -> URL {
        repositoryURL.appendingPathComponent("scripts/update.sh")
    }

    private func parseRelationship(_ raw: String) -> AppUpdateRelationship {
        switch raw {
        case "upToDate", "up_to_date":
            return .upToDate
        case "behind":
            return .behind
        case "ahead":
            return .ahead
        case "diverged":
            return .diverged
        default:
            return .upToDate
        }
    }

    private func updateStatusSummary(_ status: AppUpdateStatus) -> String {
        switch status.relationship {
        case .upToDate:
            return "Already up to date (\(shortCommit(status.localCommit)))."
        case .behind:
            return "Update available: \(shortCommit(status.localCommit)) -> \(shortCommit(status.remoteCommit))."
        case .ahead:
            return "Local checkout is already ahead of origin/main."
        case .diverged:
            return "Local branch has diverged from origin/main."
        }
    }

    private func repositoryRootURL() throws -> URL {
        if let configured = config.environment["AGENT_CONTEXT_REPO_ROOT"]?.nilIfEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            if isRepositoryRoot(url) {
                return url
            }
        }

        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executablePath = CommandLine.arguments.first ?? fileManager.currentDirectoryPath
        let executableURL = URL(fileURLWithPath: executablePath, relativeTo: cwd).standardizedFileURL
        let launchDirectory = executableURL.deletingLastPathComponent()

        if let root = findRepositoryRoot(startingAt: cwd) {
            return root
        }
        if let root = findRepositoryRoot(startingAt: launchDirectory) {
            return root
        }
        let defaultInstallRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("agent-context", isDirectory: true)
        if isRepositoryRoot(defaultInstallRoot) {
            return defaultInstallRoot
        }

        throw AppUpdateError.repositoryNotFound
    }

    private func findRepositoryRoot(startingAt startURL: URL) -> URL? {
        var candidate = startURL.standardizedFileURL
        while true {
            if isRepositoryRoot(candidate) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private func isRepositoryRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
    }

    private func runGit(arguments: [String], in repositoryURL: URL) throws -> String {
        let output = try runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: repositoryURL
        )
        guard output.terminationStatus == 0 else {
            throw AppUpdateError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                details: output.stderr.nilIfEmpty ?? output.stdout
            )
        }
        return output.stdout
    }

    private func rebuildUpdatedApp(repositoryURL: URL) throws {
        let scriptURL = repositoryURL.appendingPathComponent("scripts/build_macos_app.sh")
        if let bundlePath = currentBundlePath(),
           FileManager.default.fileExists(atPath: scriptURL.path) {
            let parent = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else {
                throw AppUpdateError.commandFailed(
                    command: "build_macos_app.sh",
                    details: "No write permission for \(parent)."
                )
            }
            let output = try runCommand(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: [scriptURL.path, bundlePath],
                currentDirectoryURL: repositoryURL
            )
            guard output.terminationStatus == 0 else {
                throw AppUpdateError.commandFailed(
                    command: "\(scriptURL.lastPathComponent) \(bundlePath)",
                    details: output.stderr.nilIfEmpty ?? output.stdout
                )
            }
            return
        }

        let output = try runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: ["build", "-c", "release", "--product", "agent-context"],
            currentDirectoryURL: repositoryURL
        )
        guard output.terminationStatus == 0 else {
            throw AppUpdateError.commandFailed(
                command: "swift build -c release --product agent-context",
                details: output.stderr.nilIfEmpty ?? output.stdout
            )
        }
    }

    private func relaunchUpdatedApp(repositoryURL: URL) throws {
        if let bundlePath = currentBundlePath() {
            try launchDetachedCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-n", bundlePath],
                currentDirectoryURL: repositoryURL
            )
            return
        }

        let releaseBinary = repositoryURL.appendingPathComponent(".build/release/agent-context")
        guard FileManager.default.isExecutableFile(atPath: releaseBinary.path) else {
            throw AppUpdateError.restartLaunchFailed(
                "Updated successfully, but release binary was not found at \(releaseBinary.path)."
            )
        }

        try launchDetachedCommand(
            executableURL: releaseBinary,
            arguments: [],
            currentDirectoryURL: repositoryURL
        )
    }

    private func currentBundlePath() -> String? {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executablePath = CommandLine.arguments.first ?? ""
        let resolvedExecutablePath = URL(fileURLWithPath: executablePath, relativeTo: cwd)
            .standardizedFileURL.path
        guard let markerRange = resolvedExecutablePath.range(of: "/Contents/MacOS/", options: .backwards) else {
            return nil
        }
        let bundlePath = String(resolvedExecutablePath[..<markerRange.lowerBound])
        guard bundlePath.hasSuffix(".app") else { return nil }
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            return nil
        }
        return bundlePath
    }

    private func shortCommit(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func scheduleRetentionSweeps() {
        runRetentionSweep(reason: "startup")

        let timer = DispatchSource.makeTimerSource(queue: retentionQueue)
        timer.schedule(deadline: .now() + 300, repeating: 3_600)
        timer.setEventHandler { [weak self] in
            self?.runRetentionSweep(reason: "periodic")
        }
        timer.resume()
        retentionTimer = timer
    }

    private func runRetentionSweep(reason: String) {
        let settings = settingsBox.get()
        let retentionManager = retentionManager
        Task.detached(priority: .utility) {
            await retentionManager.runSweep(settings: settings, reason: reason)
        }
    }
}

private struct CommandOutput: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

private struct UpdateScriptResult: Sendable {
    let status: AppUpdateStatus
    let action: String
    let message: String?
}

private final class CommandDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private func runCommand(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
) throws -> CommandOutput {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        throw AppUpdateError.commandFailed(
            command: "\(executableURL.path) \(arguments.joined(separator: " "))",
            details: error.localizedDescription
        )
    }

    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()

    let outputBox = CommandDataBox()
    let errorBox = CommandDataBox()
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        outputBox.set(data)
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        errorBox.set(data)
        group.leave()
    }

    process.waitUntilExit()
    group.wait()

    let stdout = String(data: outputBox.value(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderr = String(data: errorBox.value(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return CommandOutput(
        terminationStatus: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
}

private func launchDetachedCommand(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
) throws {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.standardOutput = nil
    process.standardError = nil
    process.standardInput = nil

    do {
        try process.run()
    } catch {
        throw AppUpdateError.commandFailed(
            command: "\(executableURL.path) \(arguments.joined(separator: " "))",
            details: error.localizedDescription
        )
    }
}
