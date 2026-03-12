import Foundation
import AppKit

final class TrackerAgent: @unchecked Sendable {
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onTranscriptStateChanged: ((Bool, Date?) -> Void)?

    private let config: TrackerConfig
    private let database: SQLiteStore
    private let logger: RuntimeLog
    private let settingsProvider: () -> AppSettings
    private let apiKeyProvider: () -> String?

    private let appMonitor = AppActivityMonitor()
    private let windowProvider = WindowContextProvider()
    private let screenshotCapture: ScreenshotCapture
    private let audioCoordinator: AudioCaptureCoordinator
    private let retryJournal: RetryJournal
    private let hourlyReporter: HourlyActivityReporter

    private let stateQueue = DispatchQueue(label: "about-time.tracker.state")
    private let analysisQueue = DispatchQueue(label: "about-time.tracker.analysis", qos: .utility)

    private var isRunning = false
    private var trackingSuppressed = false
    private var activeApp: NSRunningApplication?
    private var activeWindowContext = WindowContext(title: nil, documentPath: nil, url: nil, workspace: nil, project: nil)
    private var activeIntervalID: String?
    private var activeIntervalStart: Date?
    private var screenshotSequence = 0

    private var activationScreenshotWorkItem: DispatchWorkItem?
    private var activeScreenshotTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var inflightArtifactIDs = Set<String>()
    private let ignoredSystemBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine"
    ]

    init(
        config: TrackerConfig,
        database: SQLiteStore,
        logger: RuntimeLog,
        settingsProvider: @escaping () -> AppSettings,
        apiKeyProvider: @escaping () -> String?,
        screenshotCapture: ScreenshotCapture,
        audioCoordinator: AudioCaptureCoordinator,
        retryJournal: RetryJournal,
        hourlyReporter: HourlyActivityReporter
    ) {
        self.config = config
        self.database = database
        self.logger = logger
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.screenshotCapture = screenshotCapture
        self.audioCoordinator = audioCoordinator
        self.retryJournal = retryJournal
        self.hourlyReporter = hourlyReporter

        audioCoordinator.contextProvider = { [weak self] in
            self?.currentCaptureContext()
        }

        audioCoordinator.onChunkFinalized = { [weak self] metadata in
            self?.handleArtifactCaptured(metadata)
        }

        audioCoordinator.onRunningStateChanged = { [weak self] running, startedAt in
            self?.onTranscriptStateChanged?(running, startedAt)
        }
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }

            Task { await self.retryJournal.load() }

            self.isRunning = true
            self.trackingSuppressed = false
            self.logger.info("Recording started")
            self.wireMonitors()
            self.appMonitor.start()
            self.hourlyReporter.start()
            self.startRetryTimer()
            self.bootstrapArtifactBackfill()

            if let app = NSWorkspace.shared.frontmostApplication {
                self.handleActivated(app: app, at: Date())
            }

            DispatchQueue.main.async {
                self.onRecordingStateChanged?(true)
            }
        }
    }

    func stop(finalizePendingWork: Bool) {
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }

            self.isRunning = false
            self.trackingSuppressed = false
            self.appMonitor.stop()
            self.cancelScreenshotScheduling()
            self.stopRetryTimer()
            self.audioCoordinator.stopTranscript()
            self.closeActiveInterval(at: Date())
            DispatchQueue.main.async {
                self.onRecordingStateChanged?(false)
            }

            if finalizePendingWork {
                self.hourlyReporter.stopAndDrain(timeoutSeconds: self.config.shutdownDrainTimeoutSeconds)
            } else {
                self.hourlyReporter.stop()
            }

            self.logger.info("Recording stopped")
        }
    }

    func startTranscript() {
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            guard self.settingsProvider().transcriptControlsEnabled else { return }
            self.audioCoordinator.startTranscript()
        }
    }

    func stopTranscript() {
        stateQueue.async { [weak self] in
            self?.audioCoordinator.stopTranscript()
        }
    }

    func isRecording() -> Bool {
        stateQueue.sync { isRunning }
    }

    func isTranscriptRunning() -> Bool {
        audioCoordinator.isRunning()
    }

    private func wireMonitors() {
        appMonitor.onAppActivated = { [weak self] app, timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, app, timestamp] in
                agent.handleActivated(app: app, at: timestamp)
            }
        }

        appMonitor.onAppDeactivated = { [weak self] app, timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, app, timestamp] in
                agent.handleDeactivated(app: app, at: timestamp)
            }
        }

        appMonitor.onSystemWillSleep = { [weak self] timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, timestamp] in
                agent.suppressTracking(reason: "system sleep", at: timestamp)
            }
        }

        appMonitor.onSystemDidWake = { [weak self] timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, timestamp] in
                agent.resumeTracking(reason: "system wake", at: timestamp)
            }
        }

        appMonitor.onScreenLocked = { [weak self] timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, timestamp] in
                agent.suppressTracking(reason: "screen lock", at: timestamp)
            }
        }

        appMonitor.onScreenUnlocked = { [weak self] timestamp in
            guard let self else { return }
            let agent = self
            agent.stateQueue.async { [agent, timestamp] in
                agent.resumeTracking(reason: "screen unlock", at: timestamp)
            }
        }
    }

    private func handleActivated(app: NSRunningApplication, at timestamp: Date) {
        guard isRunning else { return }
        guard !trackingSuppressed else { return }

        if shouldIgnore(app: app) {
            closeActiveInterval(at: timestamp)
            activeApp = nil
            activeIntervalID = nil
            activeIntervalStart = nil
            activeWindowContext = WindowContext(title: nil, documentPath: nil, url: nil, workspace: nil, project: nil)
            cancelScreenshotScheduling()
            return
        }

        if activeApp?.processIdentifier != app.processIdentifier {
            closeActiveInterval(at: timestamp)
            activeApp = app
            activeWindowContext = windowProvider.context(for: app)
            activeIntervalID = UUID().uuidString
            activeIntervalStart = timestamp
            screenshotSequence = 0
            scheduleActivationScreenshot(app: app)
            scheduleRecurringScreenshot(app: app)
            logger.info("Activated app: \(app.localizedName ?? "Unknown")")
        } else {
            activeWindowContext = windowProvider.context(for: app)
        }
    }

    private func handleDeactivated(app: NSRunningApplication, at timestamp: Date) {
        guard isRunning else { return }
        guard !trackingSuppressed else { return }

        if activeApp?.processIdentifier == app.processIdentifier {
            closeActiveInterval(at: timestamp)
            activeApp = nil
            activeIntervalID = nil
            activeIntervalStart = nil
            activeWindowContext = WindowContext(title: nil, documentPath: nil, url: nil, workspace: nil, project: nil)
            cancelScreenshotScheduling()
            logger.info("Deactivated app: \(app.localizedName ?? "Unknown")")
        }
    }

    private func closeActiveInterval(at endTime: Date) {
        guard
            let app = activeApp,
            let intervalID = activeIntervalID,
            let start = activeIntervalStart,
            endTime > start
        else {
            return
        }

        let interval = ActivityInterval(
            id: intervalID,
            startTime: start,
            endTime: endTime,
            app: AppDescriptor(
                appName: app.localizedName ?? "Unknown",
                bundleID: app.bundleIdentifier,
                pid: app.processIdentifier
            ),
            window: activeWindowContext
        )

        Task {
            do {
                try await database.insertInterval(interval)
                let bucketStarts = self.intervalBucketStarts(start: start, end: endTime)
                for bucketStart in bucketStarts {
                    try await database.enqueuePendingIntervalBucket(bucketStart)
                }

                let hourStarts = self.intervalHourStarts(start: start, end: endTime)
                for hourStart in hourStarts {
                    try await database.enqueuePendingHour(hourStart)
                }
            } catch {
                logger.error("Failed to persist interval \(intervalID): \(error.localizedDescription)")
            }
        }

        activeIntervalID = nil
        activeIntervalStart = nil
    }

    private func shouldIgnore(app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, ignoredSystemBundleIDs.contains(bundleID) {
            return true
        }

        if (app.localizedName ?? "").lowercased() == "loginwindow" {
            return true
        }

        guard !settingsProvider().includeAboutTimeAppInTracking else {
            return false
        }

        if let bundleID = Bundle.main.bundleIdentifier, app.bundleIdentifier == bundleID {
            return true
        }
        return false
    }

    private func suppressTracking(reason: String, at timestamp: Date) {
        guard isRunning else { return }
        guard !trackingSuppressed else { return }

        trackingSuppressed = true
        closeActiveInterval(at: timestamp)
        activeApp = nil
        activeIntervalID = nil
        activeIntervalStart = nil
        activeWindowContext = WindowContext(title: nil, documentPath: nil, url: nil, workspace: nil, project: nil)
        cancelScreenshotScheduling()
        logger.info("Tracking paused (\(reason))")
    }

    private func resumeTracking(reason: String, at timestamp: Date) {
        guard isRunning else { return }
        guard trackingSuppressed else { return }

        trackingSuppressed = false
        logger.info("Tracking resumed (\(reason))")
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            handleActivated(app: frontmost, at: timestamp)
        }
    }

    private func scheduleActivationScreenshot(app: NSRunningApplication) {
        guard settingsProvider().captureScreenshots else { return }
        cancelActivationScreenshot()

        let expectedPID = app.processIdentifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard self.activeApp?.processIdentifier == expectedPID else { return }
                self.captureScreenshot(reason: "activation")
            }
        }

        activationScreenshotWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + config.screenshotActivationDelaySeconds, execute: workItem)
    }

    private func scheduleRecurringScreenshot(app: NSRunningApplication) {
        guard settingsProvider().captureScreenshots else { return }
        activeScreenshotTimer?.cancel()

        let expectedPID = app.processIdentifier
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + config.screenshotActivationDelaySeconds + config.screenshotWhileActiveSeconds,
            repeating: config.screenshotWhileActiveSeconds
        )

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.activeApp?.processIdentifier == expectedPID else { return }
            self.captureScreenshot(reason: "active-interval")
        }
        timer.resume()

        activeScreenshotTimer = timer
    }

    private func cancelActivationScreenshot() {
        activationScreenshotWorkItem?.cancel()
        activationScreenshotWorkItem = nil
    }

    private func cancelScreenshotScheduling() {
        cancelActivationScreenshot()
        activeScreenshotTimer?.cancel()
        activeScreenshotTimer = nil
    }

    private func captureScreenshot(reason: String) {
        guard let app = activeApp else { return }
        activeWindowContext = windowProvider.context(for: app)

        let context = (
            app: AppDescriptor(appName: app.localizedName ?? "Unknown", bundleID: app.bundleIdentifier, pid: app.processIdentifier),
            window: activeWindowContext,
            intervalID: activeIntervalID
        )

        screenshotSequence += 1
        let sequence = screenshotSequence

        screenshotCapture.capture(
            app: context.app,
            window: context.window,
            intervalID: context.intervalID,
            sequenceInInterval: sequence,
            reason: reason
        ) { [weak self] metadata in
            guard let self else { return }
            guard let metadata else {
                let hasPermission = ScreenCapturePermission.preflight()
                self.logger.error(
                    "Screenshot capture failed for \(context.app.appName) reason=\(reason) permission=\(hasPermission)"
                )
                return
            }
            self.handleArtifactCaptured(metadata)
        }
    }

    private func handleArtifactCaptured(_ metadata: ArtifactMetadata) {
        Task {
            do {
                try await database.insertEvidence(metadata)
                enqueueArtifactAnalysis(metadata: metadata, priorAttempts: 0)
            } catch {
                logger.error("Failed to persist artifact metadata \(metadata.id): \(error.localizedDescription)")
            }
        }
    }

    private func enqueueArtifactAnalysis(metadata: ArtifactMetadata, priorAttempts: Int) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            guard !self.inflightArtifactIDs.contains(metadata.id) else { return }
            self.inflightArtifactIDs.insert(metadata.id)
            defer { self.inflightArtifactIDs.remove(metadata.id) }
            self.analyzeArtifact(metadata: metadata, priorAttempts: priorAttempts)
        }
    }

    private func analyzeArtifact(metadata: ArtifactMetadata, priorAttempts: Int) {
        guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
            scheduleRetry(metadata: metadata, priorAttempts: priorAttempts, error: "missing OPENROUTER_API_KEY")
            return
        }

        let client = OpenRouterClient(config: config.openRouter, settings: settingsProvider())

        do {
            let callResult: OpenRouterCallResult
            switch metadata.kind {
            case .screenshot:
                callResult = try client.analyzeScreenshot(metadata: metadata, apiKey: apiKey)
            case .audio:
                callResult = try client.analyzeAudioChunk(metadata: metadata, apiKey: apiKey)
            }

            let analysis = decodeArtifactAnalysis(
                from: callResult.text,
                fallbackProject: metadata.window.project,
                fallbackWorkspace: metadata.window.workspace,
                fallbackTaskHint: metadata.window.title
            )

            Task {
                do {
                    try await database.markEvidenceAnalyzed(
                        evidenceID: metadata.id,
                        analysis: analysis,
                        usage: callResult.usage,
                        model: config.openRouter.model
                    )
                    await retryJournal.remove(id: metadata.id)
                } catch {
                    logger.error("Failed updating analyzed artifact \(metadata.id): \(error.localizedDescription)")
                }
            }

            logger.info("Analyzed artifact \(metadata.id) [\(metadata.kind.rawValue)]")
        } catch {
            scheduleRetry(metadata: metadata, priorAttempts: priorAttempts, error: error.localizedDescription)
        }
    }

    private func scheduleRetry(metadata: ArtifactMetadata, priorAttempts: Int, error: String) {
        let nextAttemptCount = priorAttempts + 1
        let maxBackoffStep = max(1, config.maxRetryAttempts) - 1
        let effectiveAttempts = min(nextAttemptCount, max(1, config.maxRetryAttempts))
        let exponent = min(priorAttempts, maxBackoffStep)
        let delay = min(config.retryBaseDelaySeconds * pow(2, Double(exponent)), 15 * 60)
        let nextAttemptAt = Date().addingTimeInterval(delay)

        Task {
            await retryJournal.upsert(
                RetryArtifactItem(
                    id: metadata.id,
                    metadata: metadata,
                    attempts: effectiveAttempts,
                    nextAttemptAt: nextAttemptAt,
                    lastError: error,
                    failedPermanently: false
                )
            )
            try? await database.markEvidenceFailed(evidenceID: metadata.id, errorMessage: error)
        }

        logger.error("Artifact \(metadata.id) analysis failed (attempt \(nextAttemptCount), queued for retry): \(error)")
    }

    private func startRetryTimer() {
        retryTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                let due = await self.retryJournal.dueItems(now: Date())
                for item in due {
                    self.enqueueArtifactAnalysis(metadata: item.metadata, priorAttempts: item.attempts)
                }
            }
        }
        timer.resume()

        retryTimer = timer
    }

    private func stopRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    private func bootstrapArtifactBackfill() {
        Task {
            do {
                let pending = try await database.listEvidenceForBackfill(limit: 200)
                if !pending.isEmpty {
                    logger.info("Queued \(pending.count) artifact(s) for durable analysis backfill")
                }
                for metadata in pending {
                    enqueueArtifactAnalysis(metadata: metadata, priorAttempts: 0)
                }
            } catch {
                logger.error("Artifact backfill bootstrap failed: \(error.localizedDescription)")
            }
        }
    }

    private func intervalBucketStarts(start: Date, end: Date) -> [Date] {
        guard end > start else { return [] }
        let step = TimeInterval(max(1, config.reportIntervalMinutes) * 60)
        var cursor = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / step) * step)
        var output: [Date] = []

        while cursor < end {
            output.append(cursor)
            cursor = cursor.addingTimeInterval(step)
        }

        return output
    }

    private func intervalHourStarts(start: Date, end: Date) -> [Date] {
        guard end > start else { return [] }
        let hourStep: TimeInterval = 3600
        var cursor = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / hourStep) * hourStep)
        var output: [Date] = []

        while cursor < end {
            output.append(cursor)
            cursor = cursor.addingTimeInterval(hourStep)
        }

        return output
    }

    private func currentCaptureContext() -> (app: AppDescriptor, window: WindowContext, intervalID: String?)? {
        stateQueue.sync {
            guard let app = activeApp else { return nil }
            return (
                app: AppDescriptor(appName: app.localizedName ?? "Unknown", bundleID: app.bundleIdentifier, pid: app.processIdentifier),
                window: activeWindowContext,
                intervalID: activeIntervalID
            )
        }
    }
}
