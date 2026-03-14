import Foundation

private final class WaitResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        let value = stored
        lock.unlock()
        return value
    }
}

private struct BackfillDeferredError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

final class HourlyActivityReporter: @unchecked Sendable {
    private let config: TrackerConfig
    private let database: SQLiteStore
    private let logger: RuntimeLog
    private let settingsProvider: () -> AppSettings
    private let apiKeyProvider: () -> String?
    private let mem0Ingestor: Mem0Ingestor

    private let queue = DispatchQueue(label: "agent-context.hourly.reporter", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var running = false
    private var drainingSemaphore: DispatchSemaphore?
    private let calendar: Calendar
    private let maxWorkItemsPerTick = 24
    private let mem0RetryMinimumAgeSeconds: TimeInterval = 60
    private let synthesisPromptVersion = "v2-task-segments"

    init(
        config: TrackerConfig,
        database: SQLiteStore,
        logger: RuntimeLog,
        settingsProvider: @escaping () -> AppSettings,
        apiKeyProvider: @escaping () -> String?,
        mem0Ingestor: Mem0Ingestor
    ) {
        self.config = config
        self.database = database
        self.logger = logger
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.mem0Ingestor = mem0Ingestor

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        self.calendar = calendar
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in
                self?.processTick(referenceDate: Date())
            }
            timer.resume()
            self.timer = timer

            self.logger.info("Hourly reporter started")
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            processTick(referenceDate: Date())
            logger.info("Hourly reporter stopped")
        }
    }

    func stopAndDrain(timeoutSeconds: TimeInterval) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            self.drainingSemaphore = semaphore
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.processTick(referenceDate: Date())
            self.drainingSemaphore?.signal()
            self.drainingSemaphore = nil
            self.logger.info("Hourly reporter drained")
        }

        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        if result == .timedOut {
            logger.error("Hourly reporter drain timed out")
        }
    }

    private func processTick(referenceDate: Date) {
        finalizeReadyIntervals(referenceDate: referenceDate)
        finalizeReadyHours(referenceDate: referenceDate)
        processMem0Backfill(referenceDate: referenceDate)
    }

    private func finalizeReadyIntervals(referenceDate: Date) {
        let step = TimeInterval(config.reportIntervalMinutes * 60)
        let currentBucketStart = Date(timeIntervalSince1970: floor(referenceDate.timeIntervalSince1970 / step) * step)

        let dueBuckets: [PendingIntervalBucketItem]
        do {
            dueBuckets = try wait { [self, currentBucketStart, referenceDate] in
                try await self.database.listDuePendingIntervalBuckets(
                    before: currentBucketStart,
                    now: referenceDate,
                    limit: self.maxWorkItemsPerTick
                )
            }
        } catch {
            logger.error("Failed loading pending interval bucket queue: \(error.localizedDescription)")
            return
        }

        for item in dueBuckets {
            let bucketStart = item.bucketStart
            let bucketEnd = bucketStart.addingTimeInterval(step)

            do {
                let alreadyFinalized = try wait { [self, bucketStart] in
                    try await self.database.isIntervalBucketFinalized(bucketStart)
                }
                if alreadyFinalized {
                    try wait { [self, bucketStart] in
                        try await self.database.markIntervalBucketFinalized(bucketStart)
                    }
                    continue
                }

                try finalizeIntervalBucket(start: bucketStart, end: bucketEnd)
                try wait { [self, bucketStart] in
                    try await self.database.markIntervalBucketFinalized(bucketStart)
                }
            } catch {
                let delay = retryDelay(forAttemptCount: item.attempts)
                let nextAttemptAt = Date().addingTimeInterval(delay)
                do {
                    try wait { [self, bucketStart, nextAttemptAt] in
                        try await self.database.markPendingIntervalBucketFailed(
                            bucketStart,
                            errorMessage: error.localizedDescription,
                            nextAttemptAt: nextAttemptAt
                        )
                    }
                } catch {
                    logger.error("Failed updating pending interval bucket retry state: \(error.localizedDescription)")
                }
                logger.error("Deferred interval bucket \(bucketStart): \(error.localizedDescription)")
            }
        }
    }

    private func finalizeIntervalBucket(start: Date, end: Date) throws {
        let appDurations = try wait { [self, start, end] in
            try await self.database.appDurationsForBucket(start: start, end: end)
        }
        if appDurations.isEmpty {
            return
        }

        let timeline = try wait { [self, start, end] in
            try await self.database.timelineForBucket(start: start, end: end)
        }
        let apiKey = apiKeyProvider()?.nilIfEmpty
        let client = OpenRouterClient(config: config.openRouter, settings: settingsProvider())
        var prepared: [(summary: IntervalSummary, usage: LLMUsageEvent?, segments: [TaskSegmentRecord])] = []

        for appDuration in appDurations {
            if SystemAppDenylist.isDenied(
                appName: appDuration.appName,
                bundleID: appDuration.bundleID
            ) {
                continue
            }

            let evidence = try wait {
                try await self.database.evidenceForBucket(
                    start: start,
                    end: end,
                    appName: appDuration.appName,
                    bundleID: appDuration.bundleID
                )
            }

            let summary: IntervalSummary
            var usage: LLMUsageEvent?
            var segments: [TaskSegmentRecord] = []
            let summaryID = stableIntervalSummaryID(
                bucketStart: start,
                appName: appDuration.appName,
                bundleID: appDuration.bundleID
            )

            if evidence.isEmpty {
                summary = IntervalSummary(
                    id: summaryID,
                    bucketStart: start,
                    bucketEnd: end,
                    appName: appDuration.appName,
                    bundleID: appDuration.bundleID,
                    summary: "insufficient evidence",
                    entities: [],
                    insufficientEvidence: true
                )
            } else {
                guard let apiKey else {
                    throw BackfillDeferredError(
                        description: "missing OPENROUTER_API_KEY for interval synthesis"
                    )
                }

                do {
                    let result = try client.synthesizePerAppInterval(
                        appName: appDuration.appName,
                        bundleID: appDuration.bundleID,
                        bucketStart: start,
                        bucketEnd: end,
                        evidence: evidence,
                        timeline: timeline,
                        apiKey: apiKey
                    )
                    let parsed = decodeStructuredSynthesis(
                        from: result.text,
                        defaultTask: evidence.compactMap { $0.analysis?.task }.first,
                        defaultProject: evidence.compactMap { $0.analysis?.project }.first,
                        defaultWorkspace: evidence.compactMap { $0.analysis?.workspace }.first,
                        defaultAppName: appDuration.appName,
                        defaultBundleID: appDuration.bundleID
                    )
                    summary = IntervalSummary(
                        id: summaryID,
                        bucketStart: start,
                        bucketEnd: end,
                        appName: appDuration.appName,
                        bundleID: appDuration.bundleID,
                        summary: parsed.summary,
                        entities: parsed.entities,
                        insufficientEvidence: parsed.insufficientEvidence
                    )
                    segments = makeTaskSegmentRecords(
                        scope: "interval",
                        start: start,
                        end: end,
                        defaultAppName: appDuration.appName,
                        defaultBundleID: appDuration.bundleID,
                        drafts: parsed.taskSegments,
                        sourceSummaryID: summaryID
                    )
                    usage = result.usage
                } catch {
                    throw BackfillDeferredError(
                        description: "per-app interval synthesis failed for \(appDuration.appName): \(error.localizedDescription)"
                    )
                }
            }

            prepared.append((summary, usage, segments))
        }

        for entry in prepared {
            let summary = entry.summary
            let usageSnapshot = entry.usage
            let model = usageSnapshot?.model.nilIfEmpty ?? self.config.openRouter.model
            try wait {
                try await self.database.saveIntervalSummary(summary, usage: usageSnapshot, model: model)
            }
            if !entry.segments.isEmpty {
                try wait {
                    try await self.database.saveTaskSegments(entry.segments)
                }
            }

            let payload = MemoryPayload(
                id: "interval-\(summary.id)",
                scope: "interval",
                occurredAt: summary.bucketStart,
                appName: summary.appName,
                project: summary.entities.first,
                summary: summary.summary,
                entities: summary.entities,
                metadata: [
                    "bucket_start": ISO8601DateFormatter().string(from: summary.bucketStart),
                    "bucket_end": ISO8601DateFormatter().string(from: summary.bucketEnd)
                ]
            )
            persistMemory(payload)

            for segment in entry.segments {
                persistMemory(taskSegmentMemoryPayload(segment))
            }
        }
    }

    private func finalizeReadyHours(referenceDate: Date) {
        let currentHourStart = calendar.hourStart(for: referenceDate)

        let dueHours: [PendingHourItem]
        do {
            dueHours = try wait { [self, currentHourStart, referenceDate] in
                try await self.database.listDuePendingHours(
                    before: currentHourStart,
                    now: referenceDate,
                    limit: self.maxWorkItemsPerTick
                )
            }
        } catch {
            logger.error("Failed loading pending hour queue: \(error.localizedDescription)")
            return
        }

        for item in dueHours {
            let hourStart = item.hourStart
            let hourEnd = hourStart.addingTimeInterval(3600)

            do {
                let alreadyFinalized = try wait { [self, hourStart] in
                    try await self.database.isHourFinalized(hourStart)
                }
                if alreadyFinalized {
                    try wait { [self, hourStart] in
                        try await self.database.markHourFinalized(hourStart)
                    }
                    continue
                }

                guard areAllIntervalBucketsFinalized(hourStart: hourStart, hourEnd: hourEnd) else {
                    throw BackfillDeferredError(
                        description: "hour dependencies are not finalized yet"
                    )
                }

                try finalizeHour(hourStart: hourStart, hourEnd: hourEnd)
                try wait { [self, hourStart] in
                    try await self.database.markHourFinalized(hourStart)
                }
            } catch {
                let delay = retryDelay(forAttemptCount: item.attempts)
                let nextAttemptAt = Date().addingTimeInterval(delay)
                do {
                    try wait { [self, hourStart, nextAttemptAt] in
                        try await self.database.markPendingHourFailed(
                            hourStart,
                            errorMessage: error.localizedDescription,
                            nextAttemptAt: nextAttemptAt
                        )
                    }
                } catch {
                    logger.error("Failed updating pending hour retry state: \(error.localizedDescription)")
                }
                logger.error("Deferred hour synthesis \(hourStart): \(error.localizedDescription)")
            }
        }
    }

    private func areAllIntervalBucketsFinalized(hourStart: Date, hourEnd: Date) -> Bool {
        var bucketStart = hourStart
        let step = TimeInterval(config.reportIntervalMinutes * 60)
        while bucketStart < hourEnd {
            let finalizedBucketStart = bucketStart
            do {
                let done = try wait { [self, finalizedBucketStart] in
                    try await self.database.isIntervalBucketFinalized(finalizedBucketStart)
                }
                if !done {
                    return false
                }
            } catch {
                return false
            }
            bucketStart = bucketStart.addingTimeInterval(step)
        }
        return true
    }

    private func finalizeHour(hourStart: Date, hourEnd: Date) throws {
        let intervalSummaries = try wait { [self, hourStart, hourEnd] in
            try await self.database.listIntervalSummaries(hourStart: hourStart, hourEnd: hourEnd)
        }
        let timeline = try wait { [self, hourStart, hourEnd] in
            try await self.database.timelineForBucket(start: hourStart, end: hourEnd)
        }

        let summary: HourSummary
        var usage: LLMUsageEvent?
        var hourSegments: [TaskSegmentRecord] = []
        let hourSummaryID = stableHourSummaryID(hourStart: hourStart)

        if intervalSummaries.isEmpty {
            summary = HourSummary(
                id: hourSummaryID,
                hourStart: hourStart,
                hourEnd: hourEnd,
                summary: "insufficient evidence"
            )
        } else {
            guard let apiKey = apiKeyProvider()?.nilIfEmpty else {
                throw BackfillDeferredError(
                    description: "missing OPENROUTER_API_KEY for hour synthesis"
                )
            }

            do {
                let client = OpenRouterClient(config: config.openRouter, settings: settingsProvider())
                let result = try client.synthesizeHour(
                    hourStart: hourStart,
                    hourEnd: hourEnd,
                    intervalSummaries: intervalSummaries,
                    timeline: timeline,
                    apiKey: apiKey
                )
                let parsed = decodeStructuredSynthesis(from: result.text)
                summary = HourSummary(
                    id: hourSummaryID,
                    hourStart: hourStart,
                    hourEnd: hourEnd,
                    summary: parsed.summary
                )
                hourSegments = makeTaskSegmentRecords(
                    scope: "hour",
                    start: hourStart,
                    end: hourEnd,
                    defaultAppName: nil,
                    defaultBundleID: nil,
                    drafts: parsed.taskSegments,
                    sourceSummaryID: hourSummaryID
                )
                usage = result.usage
            } catch {
                throw BackfillDeferredError(
                    description: "hour synthesis failed for \(hourStart): \(error.localizedDescription)"
                )
            }
        }

        let usageSnapshot = usage
        let model = usageSnapshot?.model.nilIfEmpty ?? self.config.openRouter.model
        try wait { [self, summary, usageSnapshot, model] in
            try await self.database.saveHourSummary(summary, usage: usageSnapshot, model: model)
        }
        if !hourSegments.isEmpty {
            try wait { [self, hourSegments] in
                try await self.database.saveTaskSegments(hourSegments)
            }
        }

        let payload = MemoryPayload(
            id: "hour-\(summary.id)",
            scope: "hour",
            occurredAt: summary.hourStart,
            appName: nil,
            project: nil,
            summary: summary.summary,
            entities: intervalSummaries.flatMap(\.entities),
            metadata: [
                "hour_start": ISO8601DateFormatter().string(from: summary.hourStart),
                "hour_end": ISO8601DateFormatter().string(from: summary.hourEnd)
            ]
        )
        persistMemory(payload)

        for segment in hourSegments {
            persistMemory(taskSegmentMemoryPayload(segment))
        }
    }

    private func processMem0Backfill(referenceDate: Date) {
        let retryBefore = referenceDate.addingTimeInterval(-mem0RetryMinimumAgeSeconds)
        let candidates: [PendingMem0Item]

        do {
            candidates = try wait { [self, retryBefore] in
                try await self.database.listMem0BackfillCandidates(
                    retryBefore: retryBefore,
                    limit: self.maxWorkItemsPerTick
                )
            }
        } catch {
            logger.error("Failed loading Mem0 backfill queue: \(error.localizedDescription)")
            return
        }

        guard !candidates.isEmpty else {
            return
        }

        for item in candidates {
            let result = mem0Ingestor.ingest(payload: item.payload, settings: settingsProvider())
            do {
                try wait { [self, item, result] in
                    try await self.database.saveMemoryPayload(
                        item.payload,
                        status: result.status,
                        responseJSON: result.responseJSON
                    )
                }
            } catch {
                logger.error("Failed persisting Mem0 retry result for \(item.payload.id): \(error.localizedDescription)")
            }
        }
    }

    private func makeTaskSegmentRecords(
        scope: String,
        start: Date,
        end: Date,
        defaultAppName: String?,
        defaultBundleID: String?,
        drafts: [TaskSegmentDraft],
        sourceSummaryID: String
    ) -> [TaskSegmentRecord] {
        guard !drafts.isEmpty else { return [] }

        return drafts.enumerated().map { index, draft in
            let normalizedTask = draft.task.nilIfEmpty ?? "unknown task"
            let appName = draft.appName?.nilIfEmpty ?? defaultAppName
            let bundleID = draft.bundleID?.nilIfEmpty ?? defaultBundleID
            let project = draft.project?.nilIfEmpty
            let workspace = draft.workspace?.nilIfEmpty
            let entities = uniqueList(
                draft.entities
                + draft.actions
                + [normalizedTask, project, workspace, draft.repo, draft.document].compactMap { $0 }
            )
            let summary = draftSummary(from: draft)
            let id = stableTaskSegmentID(
                scope: scope,
                start: start,
                end: end,
                appName: appName,
                bundleID: bundleID,
                task: normalizedTask,
                index: index
            )

            return TaskSegmentRecord(
                id: id,
                scope: scope,
                startTime: start,
                endTime: end,
                occurredAt: start,
                appName: appName,
                bundleID: bundleID,
                project: project,
                workspace: workspace,
                repo: draft.repo?.nilIfEmpty,
                document: draft.document?.nilIfEmpty,
                url: draft.url?.nilIfEmpty,
                task: normalizedTask,
                issueOrGoal: draft.issueOrGoal?.nilIfEmpty,
                actions: uniqueList(draft.actions),
                outcome: draft.outcome?.nilIfEmpty,
                nextStep: draft.nextStep?.nilIfEmpty,
                status: draft.status,
                confidence: max(0, min(1, draft.confidence)),
                evidenceRefs: uniqueList(draft.evidenceRefs),
                entities: entities,
                summary: summary,
                sourceSummaryID: sourceSummaryID,
                promptVersion: synthesisPromptVersion
            )
        }
    }

    private func taskSegmentMemoryPayload(_ segment: TaskSegmentRecord) -> MemoryPayload {
        var metadata: [String: String] = [
            "scope": segment.scope,
            "status": segment.status.rawValue,
            "confidence": String(format: "%.2f", segment.confidence),
            "start_time": ISO8601DateFormatter().string(from: segment.startTime),
            "end_time": ISO8601DateFormatter().string(from: segment.endTime),
            "prompt_version": segment.promptVersion
        ]

        if let issue = segment.issueOrGoal?.nilIfEmpty {
            metadata["issue_or_goal"] = issue
        }
        if let outcome = segment.outcome?.nilIfEmpty {
            metadata["outcome"] = outcome
        }
        if let next = segment.nextStep?.nilIfEmpty {
            metadata["next_step"] = next
        }
        if !segment.actions.isEmpty {
            metadata["actions"] = segment.actions.joined(separator: " | ")
        }
        if !segment.evidenceRefs.isEmpty {
            metadata["evidence_refs"] = segment.evidenceRefs.joined(separator: " | ")
        }
        if let workspace = segment.workspace?.nilIfEmpty {
            metadata["workspace"] = workspace
        }
        if let repo = segment.repo?.nilIfEmpty {
            metadata["repo"] = repo
        }
        if let document = segment.document?.nilIfEmpty {
            metadata["document"] = document
        }
        if let url = segment.url?.nilIfEmpty {
            metadata["url"] = url
        }

        return MemoryPayload(
            id: "task-segment-\(segment.id)",
            scope: "task_segment",
            occurredAt: segment.occurredAt,
            appName: segment.appName,
            project: segment.project,
            summary: taskSegmentContent(segment),
            entities: segment.entities,
            metadata: metadata
        )
    }

    private func taskSegmentContent(_ segment: TaskSegmentRecord) -> String {
        var fragments: [String] = []
        fragments.append("Task: \(segment.task)")
        fragments.append("Status: \(segment.status.rawValue)")
        if let issue = segment.issueOrGoal?.nilIfEmpty {
            fragments.append("Issue/Goal: \(issue)")
        }
        if !segment.actions.isEmpty {
            fragments.append("Actions: \(segment.actions.joined(separator: "; "))")
        }
        if let outcome = segment.outcome?.nilIfEmpty {
            fragments.append("Outcome: \(outcome)")
        }
        if let next = segment.nextStep?.nilIfEmpty {
            fragments.append("Next step: \(next)")
        }
        if let project = segment.project?.nilIfEmpty {
            fragments.append("Project: \(project)")
        }
        return fragments.joined(separator: " | ")
    }

    private func draftSummary(from draft: TaskSegmentDraft) -> String {
        var lines: [String] = []
        lines.append(draft.task)
        if let issue = draft.issueOrGoal?.nilIfEmpty {
            lines.append("Goal: \(issue)")
        }
        if let outcome = draft.outcome?.nilIfEmpty {
            lines.append("Outcome: \(outcome)")
        }
        if let next = draft.nextStep?.nilIfEmpty {
            lines.append("Next: \(next)")
        }
        return lines.joined(separator: " • ")
    }

    private func stableTaskSegmentID(
        scope: String,
        start: Date,
        end: Date,
        appName: String?,
        bundleID: String?,
        task: String,
        index: Int
    ) -> String {
        let token = (bundleID?.nilIfEmpty ?? appName?.nilIfEmpty ?? "global")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let taskToken = task
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "\(scope)-segment-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))-\(token)-\(taskToken)-\(index)"
    }

    private func uniqueList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for raw in values {
            guard let normalized = raw.nilIfEmpty else { continue }
            if seen.insert(normalized).inserted {
                output.append(normalized)
            }
        }
        return output
    }

    private func retryDelay(forAttemptCount attempts: Int) -> TimeInterval {
        let maxBackoffStep = max(1, config.maxRetryAttempts) - 1
        let exponent = min(max(0, attempts), maxBackoffStep)
        return min(config.retryBaseDelaySeconds * pow(2, Double(exponent)), 15 * 60)
    }

    private func stableIntervalSummaryID(bucketStart: Date, appName: String, bundleID: String?) -> String {
        let token = (bundleID?.nilIfEmpty ?? appName)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "interval-\(Int(bucketStart.timeIntervalSince1970))-\(token)"
    }

    private func stableHourSummaryID(hourStart: Date) -> String {
        "hour-\(Int(hourStart.timeIntervalSince1970))"
    }

    private func persistMemory(_ payload: MemoryPayload) {
        do {
            try wait { [self, payload] in
                try await self.database.saveMemoryPayload(payload, status: "pending", responseJSON: nil)
            }

            let result = mem0Ingestor.ingest(payload: payload, settings: settingsProvider())
            try wait { [self, payload, result] in
                try await self.database.saveMemoryPayload(payload, status: result.status, responseJSON: result.responseJSON)
            }
        } catch {
            logger.error("Memory persistence failed for \(payload.id): \(error.localizedDescription)")
        }
    }

    private func wait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = WaitResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch box.get() {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw NSError(domain: "HourlyActivityReporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Task produced no result"])
        }
    }
}
