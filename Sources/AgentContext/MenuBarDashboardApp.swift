import Foundation
import AppKit
import SwiftUI
import ApplicationServices

@MainActor
enum AgentContextMenuBarApp {
    static func run() {
        let app = NSApplication.shared
        let delegate = AgentContextAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AgentContextAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: TrackerRuntime?
    private var store: ActivityDashboardStore?
    private var windowController: DashboardWindowController?
    private var menuController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try TrackerRuntime()
            let store = ActivityDashboardStore(runtime: runtime)
            let windowController = DashboardWindowController(store: store)

            let menuController = MenuBarController(
                onToggleDashboard: { [weak windowController] in
                    windowController?.toggleVisibility()
                },
                onStartRecording: { [weak store] in store?.startRecording() },
                onStopRecording: { [weak store] in store?.stopRecording() },
                onStartTranscript: { [weak store] in store?.startTranscript() },
                onStopTranscript: { [weak store] in store?.stopTranscript() },
                onQuit: { [weak store] in store?.requestQuit() }
            )

            store.onRecordingStateChanged = { [weak menuController] isRecording in
                menuController?.setRecordingState(isRecording)
            }
            store.onTranscriptStateChanged = { [weak menuController] isTranscriptRunning in
                menuController?.setTranscriptState(isTranscriptRunning)
            }

            self.runtime = runtime
            self.store = store
            self.windowController = windowController
            self.menuController = menuController

            menuController.setRecordingState(store.isRecording)
            menuController.setTranscriptState(store.isTranscriptRunning)

            for line in runtime.startupMessages() {
                print(line)
            }

            if !AXIsProcessTrusted() {
                print("Accessibility permission missing. Grant in System Settings > Privacy & Security > Accessibility.")
            }
            if !ScreenCapturePermission.preflight() {
                print("Screen recording permission missing. A request will be made when first screenshot is captured.")
            }
        } catch {
            fputs("fatal: \(error.localizedDescription)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let onToggleDashboard: () -> Void
    private let onStartRecording: () -> Void
    private let onStopRecording: () -> Void
    private let onStartTranscript: () -> Void
    private let onStopTranscript: () -> Void
    private let onQuit: () -> Void

    private var isRecording = false
    private var isTranscriptRunning = false

    init(
        onToggleDashboard: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartTranscript: @escaping () -> Void,
        onStopTranscript: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggleDashboard = onToggleDashboard
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.onStartTranscript = onStartTranscript
        self.onStopTranscript = onStopTranscript
        self.onQuit = onQuit
        super.init()

        if let button = statusItem.button {
            button.title = "AC ○"
            button.target = self
            button.action = #selector(handleStatusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func setRecordingState(_ running: Bool) {
        isRecording = running
        refreshTitle()
    }

    func setTranscriptState(_ running: Bool) {
        isTranscriptRunning = running
        refreshTitle()
    }

    private func refreshTitle() {
        var title = isRecording ? "AC ●" : "AC ○"
        if isTranscriptRunning {
            title += " T"
        }
        statusItem.button?.title = title
    }

    @objc private func handleStatusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        onToggleDashboard()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let recordingItem = NSMenuItem(
            title: isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(handleRecordingMenuAction),
            keyEquivalent: ""
        )
        recordingItem.target = self
        menu.addItem(recordingItem)

        let transcriptItem = NSMenuItem(
            title: isTranscriptRunning ? "Stop Transcript" : "Start Transcript",
            action: #selector(handleTranscriptMenuAction),
            keyEquivalent: ""
        )
        transcriptItem.target = self
        transcriptItem.isEnabled = isRecording
        menu.addItem(transcriptItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(handleQuitMenuAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func handleRecordingMenuAction() {
        if isRecording {
            onStopRecording()
        } else {
            onStartRecording()
        }
    }

    @objc private func handleTranscriptMenuAction() {
        if isTranscriptRunning {
            onStopTranscript()
        } else {
            onStartTranscript()
        }
    }

    @objc private func handleQuitMenuAction() {
        onQuit()
    }
}

@MainActor
final class DashboardWindowController: NSWindowController {
    init(store: ActivityDashboardStore) {
        let view = ActivityDashboardView(store: store)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Context"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        store.onCloseDashboard = { [weak window] in
            window?.orderOut(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct OpenRouterModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let inputModalities: [String]

    var normalizedInputModalities: Set<String> {
        Set(inputModalities.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    func supportsAnyInputModalities(_ modalities: Set<String>) -> Bool {
        !normalizedInputModalities.isDisjoint(with: modalities)
    }
}

@MainActor
final class ActivityDashboardStore: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscriptRunning = false
    @Published var transcriptElapsedText = ""

    @Published var selectedDay: Date = Date() {
        didSet {
            selectedHour = nil
            refreshDashboard()
            refreshWeekUsage()
        }
    }
    @Published var selectedHour: Int? {
        didSet {
            applySelectionFromRows()
        }
    }

    @Published var rows: [DashboardHourRow] = []
    @Published var hourlyUsage: [DashboardHourUsage] = []
    @Published var dayAppRows: [DashboardDayAppRow] = []
    @Published var weekUsage: [DashboardWeekdayUsage] = []
    @Published var selectedDayAppRow: DashboardDayAppRow?
    @Published var appSearchText = ""
    @Published var evidenceDetails: [EvidenceDetailItem] = []

    @Published var isSettingsPresented = false
    @Published var settingsDraft: AppSettings
    @Published var settingsMessage: String?
    @Published var settingsError: String?
    @Published var updateStatus: AppUpdateStatus?
    @Published var updateMessage: String?
    @Published var updateError: String?
    @Published var isCheckingForUpdates = false
    @Published var isApplyingUpdate = false
    @Published var usageToday = LLMUsageTotals()
    @Published var usageAllTime = LLMUsageTotals()
    @Published var availableOpenRouterModels: [OpenRouterModelOption] = []
    @Published var openRouterModelsError: String?
    @Published var isLoadingOpenRouterModels = false

    @Published var memoryQueryText = ""
    @Published var memoryQueryResult = ""
    @Published var isMemoryQueryLoading = false
    @Published var memoryQueryError: String?

    @Published var isQuitFinalizing = false

    var onCloseDashboard: (() -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onTranscriptStateChanged: ((Bool) -> Void)?

    private let runtime: TrackerRuntime
    private var refreshTimer: Timer?
    private var transcriptTimer: Timer?
    private var memoryQueryTask: Task<Void, Never>?

    init(runtime: TrackerRuntime) {
        self.runtime = runtime
        settingsDraft = runtime.loadSettings()

        isRecording = runtime.isRecording
        isTranscriptRunning = runtime.isTranscriptRunning

        runtime.onRecordingStateChanged = { [weak self] running in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = running
                self.onRecordingStateChanged?(running)
                if !running {
                    self.isTranscriptRunning = false
                    self.onTranscriptStateChanged?(false)
                    self.stopTranscriptTimer()
                }
                self.refreshDashboard()
            }
        }

        runtime.onTranscriptStateChanged = { [weak self] running, startedAt in
            Task { @MainActor in
                guard let self else { return }
                self.isTranscriptRunning = running
                self.onTranscriptStateChanged?(running)
                if running {
                    self.startTranscriptTimer(startedAt: startedAt ?? Date())
                } else {
                    self.stopTranscriptTimer()
                }
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDashboard()
            }
        }

        if isTranscriptRunning {
            startTranscriptTimer(startedAt: runtime.currentTranscriptStartedAt ?? Date())
        }

        refreshDashboard()
        refreshWeekUsage()
    }

    func startRecording() {
        runtime.startRecording()
        refreshDashboard()
    }

    func stopRecording() {
        runtime.stopRecording(finalizePendingWork: false)
        refreshDashboard()
    }

    func startTranscript() {
        let settings = runtime.loadSettings()
        if settings.requireTranscriptConsent {
            let alert = NSAlert()
            alert.messageText = "Start Transcript"
            alert.informativeText = "Agent Context will capture system audio in rolling 2-minute chunks until you click Stop Transcript or stop recording."
            alert.addButton(withTitle: "Start Transcript")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                return
            }
        }

        runtime.startTranscript()
    }

    func stopTranscript() {
        runtime.stopTranscript()
    }

    func selectDayApp(_ row: DashboardDayAppRow) {
        selectedDayAppRow = row
        loadEvidence(for: row)
    }

    func selectDay(_ day: Date) {
        selectedHour = nil
        selectedDay = day
    }

    func selectHour(_ hour: Int) {
        selectedHour = (selectedHour == hour) ? nil : hour
    }

    func clearHourSelection() {
        selectedHour = nil
    }

    var selectedRangeTitle: String {
        guard let selectedHour else {
            return "All Day"
        }
        return String(format: "%02d:00-%02d:00", selectedHour, selectedHour + 1)
    }

    func refreshDashboard() {
        Task {
            do {
                let snapshot = try await runtime.fetchDashboard(day: selectedDay)
                await MainActor.run {
                    rows = snapshot.rows
                    hourlyUsage = aggregateHourlyUsage(from: snapshot.rows)
                    usageToday = snapshot.usageToday
                    usageAllTime = snapshot.usageAllTime

                    applySelectionFromRows()

                    let selectedDayTotal = totalDuration(from: snapshot.rows)
                    updateWeekUsageSelectedDay(total: selectedDayTotal)
                }
            } catch {
                await MainActor.run {
                    settingsError = "Dashboard refresh failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func openSettings() {
        settingsDraft = runtime.loadSettings()
        settingsMessage = nil
        settingsError = nil
        updateMessage = nil
        updateError = nil
        openRouterModelsError = nil
        settingsDraft.openRouterModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterModel)
        settingsDraft.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterAudioModel)
        settingsDraft.openRouterTextModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterTextModel)
        availableOpenRouterModels = withSelectedModels(availableOpenRouterModels)
        isSettingsPresented = true
        checkForAppUpdate()
        refreshOpenRouterModels(force: true)
    }

    func saveSettings() {
        do {
            settingsDraft.openRouterModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterModel)
            settingsDraft.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterAudioModel)
            settingsDraft.openRouterTextModel = AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterTextModel)
            try runtime.saveSettings(settingsDraft)
            settingsMessage = "Settings saved"
            settingsError = nil
            refreshDashboard()
        } catch {
            settingsError = error.localizedDescription
            settingsMessage = nil
        }
    }

    func checkForAppUpdate() {
        guard !isCheckingForUpdates, !isApplyingUpdate else { return }
        isCheckingForUpdates = true
        updateError = nil

        let runtime = runtime
        Task { [weak self] in
            do {
                let status = try await Task.detached(priority: .utility) {
                    try runtime.checkForUpdatesAgainstMain()
                }.value

                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingForUpdates = false
                    self.updateStatus = status
                    self.updateMessage = self.updateSummaryText(status)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isCheckingForUpdates = false
                    self.updateError = error.localizedDescription
                }
            }
        }
    }

    func applyAppUpdate() {
        guard !isApplyingUpdate, !isCheckingForUpdates else { return }
        isApplyingUpdate = true
        updateError = nil

        let runtime = runtime
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try runtime.updateFromMainRebuildAndRestart()
                }.value

                await MainActor.run {
                    guard let self else { return }
                    self.isApplyingUpdate = false
                    self.updateStatus = result.status
                    self.updateMessage = result.message
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isApplyingUpdate = false
                    self.updateError = error.localizedDescription
                }
            }
        }
    }

    func refreshOpenRouterModels(force: Bool = false) {
        guard !isLoadingOpenRouterModels else { return }
        if !force && !availableOpenRouterModels.isEmpty {
            return
        }

        isLoadingOpenRouterModels = true
        openRouterModelsError = nil

        let endpoint = runtime.config.openRouter.endpoint
        let env = runtime.config.environment
        let settings = settingsDraft
        let apiKey = AppSettingsStore.resolvedOpenRouterKey(settings: settings, env: env)

        Task { [weak self] in
            do {
                let models = try await Self.fetchOpenRouterModels(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    appNameHeader: settings.openRouterAppNameHeader,
                    refererHeader: settings.openRouterRefererHeader
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingOpenRouterModels = false
                    self.availableOpenRouterModels = self.withSelectedModels(models)
                    self.settingsDraft.openRouterModel = AppSettings.normalizedOpenRouterModel(self.settingsDraft.openRouterModel)
                    self.settingsDraft.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(self.settingsDraft.openRouterAudioModel)
                    self.settingsDraft.openRouterTextModel = AppSettings.normalizedOpenRouterModel(self.settingsDraft.openRouterTextModel)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingOpenRouterModels = false
                    self.availableOpenRouterModels = self.withSelectedModels(self.availableOpenRouterModels)
                    self.openRouterModelsError = error.localizedDescription
                }
            }
        }
    }

    func runMemoryQuery() {
        memoryQueryTask?.cancel()

        let query = memoryQueryText
        memoryQueryResult = ""
        memoryQueryError = nil
        isMemoryQueryLoading = true

        let runtime = runtime
        memoryQueryTask = Task { [weak self] in
            let answer = await Task.detached(priority: .userInitiated) {
                await runtime.runMemoryQuery(query)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isMemoryQueryLoading = false
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.memoryQueryError = "No response generated. Check Mem0/OpenRouter settings and try again."
                    self.memoryQueryResult = ""
                } else {
                    self.memoryQueryResult = answer
                }
            }
        }
    }

    func requestQuit() {
        guard !isQuitFinalizing else { return }
        isQuitFinalizing = true
        isSettingsPresented = false
        onCloseDashboard?()

        // Best-effort fast shutdown; quit should not block on pending analysis drains.
        runtime.stopTranscript()
        runtime.stopRecording(finalizePendingWork: false)
        NSApplication.shared.terminate(nil)
    }

    func closeDashboard() {
        onCloseDashboard?()
    }

    private func refreshWeekUsage() {
        let targetDay = selectedDay
        Task {
            do {
                let weekDays = weekDaysContaining(targetDay)
                var items: [DashboardWeekdayUsage] = []
                for day in weekDays {
                    let duration = try await runtime.dayUsageTotal(day: day)
                    let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: day)
                    items.append(
                        DashboardWeekdayUsage(
                            id: String(Int(dayStart.timeIntervalSince1970)),
                            day: dayStart,
                            duration: duration
                        )
                    )
                }

                await MainActor.run {
                    weekUsage = items.sorted { $0.day < $1.day }
                }
            } catch {
                await MainActor.run {
                    settingsError = "Week usage refresh failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func weekDaysContaining(_ day: Date) -> [Date] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = 2
        let startOfDay = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let offset = (weekday + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -offset, to: startOfDay) else {
            return [startOfDay]
        }

        return (0..<7).compactMap { index in
            calendar.date(byAdding: .day, value: index, to: weekStart)
        }
    }

    private func aggregateHourlyUsage(from rows: [DashboardHourRow]) -> [DashboardHourUsage] {
        rows.sorted { $0.hour < $1.hour }.map { row in
            let total = row.blocks.reduce(0) { $0 + $1.duration }
            return DashboardHourUsage(id: row.hour, hour: row.hour, duration: total)
        }
    }

    private func aggregateDayAppRows(from rows: [DashboardHourRow]) -> [DashboardDayAppRow] {
        var grouped: [String: DashboardDayAppRow] = [:]

        for row in rows {
            for block in row.blocks {
                let key = block.bundleID ?? block.appName
                if var existing = grouped[key] {
                    existing = DashboardDayAppRow(
                        id: existing.id,
                        appName: existing.appName,
                        bundleID: existing.bundleID,
                        duration: existing.duration + block.duration,
                        icon: existing.icon
                    )
                    grouped[key] = existing
                } else {
                    grouped[key] = DashboardDayAppRow(
                        id: key,
                        appName: block.appName,
                        bundleID: block.bundleID,
                        duration: block.duration,
                        icon: block.icon
                    )
                }
            }
        }

        return grouped.values.sorted { lhs, rhs in
            if abs(lhs.duration - rhs.duration) > 0.1 {
                return lhs.duration > rhs.duration
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    private func updateWeekUsageSelectedDay(total: TimeInterval) {
        let selectedStart = Calendar.autoupdatingCurrent.startOfDay(for: selectedDay)
        if let index = weekUsage.firstIndex(where: {
            Calendar.autoupdatingCurrent.isDate($0.day, inSameDayAs: selectedStart)
        }) {
            weekUsage[index] = DashboardWeekdayUsage(
                id: weekUsage[index].id,
                day: weekUsage[index].day,
                duration: total
            )
        }
    }

    private func totalDuration(from rows: [DashboardHourRow]) -> TimeInterval {
        rows.reduce(0) { accumulator, row in
            accumulator + row.blocks.reduce(0) { $0 + $1.duration }
        }
    }

    private func selectedRows(from rows: [DashboardHourRow]) -> [DashboardHourRow] {
        guard let selectedHour else { return rows }
        return rows.filter { $0.hour == selectedHour }
    }

    private func applySelectionFromRows() {
        dayAppRows = aggregateDayAppRows(from: selectedRows(from: rows))

        guard let selected = selectedDayAppRow else {
            evidenceDetails = []
            return
        }

        if let refreshed = dayAppRows.first(where: { $0.id == selected.id }) {
            selectedDayAppRow = refreshed
            loadEvidence(for: refreshed)
        } else {
            selectedDayAppRow = nil
            evidenceDetails = []
        }
    }

    private func loadEvidence(for row: DashboardDayAppRow) {
        Task {
            do {
                let calendar = Calendar.autoupdatingCurrent
                let dayStart = calendar.startOfDay(for: selectedDay)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                let rangeStart: Date
                let rangeEnd: Date

                if let selectedHour,
                   let hourStart = calendar.date(byAdding: .hour, value: selectedHour, to: dayStart) {
                    rangeStart = hourStart
                    rangeEnd = hourStart.addingTimeInterval(3600)
                } else {
                    rangeStart = dayStart
                    rangeEnd = dayEnd
                }

                let details = try await runtime.evidenceDetails(
                    hourStart: rangeStart,
                    hourEnd: rangeEnd,
                    appName: row.appName,
                    bundleID: row.bundleID
                )
                await MainActor.run {
                    evidenceDetails = details
                }
            } catch {
                await MainActor.run {
                    evidenceDetails = []
                }
            }
        }
    }

    private func startTranscriptTimer(startedAt: Date) {
        stopTranscriptTimer()
        transcriptElapsedText = elapsedText(from: startedAt)

        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.transcriptElapsedText = self.elapsedText(from: startedAt)
            }
        }
    }

    private func stopTranscriptTimer() {
        transcriptTimer?.invalidate()
        transcriptTimer = nil
        transcriptElapsedText = ""
    }

    private func updateSummaryText(_ status: AppUpdateStatus) -> String {
        let localShort = String(status.localCommit.prefix(8))
        let remoteShort = String(status.remoteCommit.prefix(8))

        switch status.relationship {
        case .upToDate:
            return "Up to date (\(localShort))."
        case .behind:
            return "Update available: \(localShort) → \(remoteShort)."
        case .ahead:
            return "Local checkout is ahead of origin/main."
        case .diverged:
            return "Local branch has diverged from origin/main."
        }
    }

    private func elapsedText(from start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func withSelectedModels(_ models: [OpenRouterModelOption]) -> [OpenRouterModelOption] {
        var byID = [String: OpenRouterModelOption]()
        for model in models {
            byID[model.id] = model
        }

        for selected in selectedModelIDs() {
            if byID[selected] == nil {
                byID[selected] = OpenRouterModelOption(id: selected, name: nil, inputModalities: [])
            }
        }

        return byID.values.sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private func selectedModelIDs() -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        let candidates = [
            AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterModel),
            AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterAudioModel),
            AppSettings.normalizedOpenRouterModel(settingsDraft.openRouterTextModel)
        ]
        for candidate in candidates {
            guard seen.insert(candidate).inserted else { continue }
            output.append(candidate)
        }
        return output
    }

    private static func fetchOpenRouterModels(
        endpoint: URL,
        apiKey: String?,
        appNameHeader: String?,
        refererHeader: String?
    ) async throws -> [OpenRouterModelOption] {
        let modelsURL = modelsURL(from: endpoint)
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let appNameHeader, !appNameHeader.isEmpty {
            request.setValue(appNameHeader, forHTTPHeaderField: "X-Title")
        }
        if let refererHeader, !refererHeader.isEmpty {
            request.setValue(refererHeader, forHTTPHeaderField: "HTTP-Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "OpenRouterModels",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Model list request failed (\(statusCode)): \(body)"]
            )
        }

        let decoded = try JSONDecoder().decode(OpenRouterModelListResponse.self, from: data)
        let options = decoded.data.compactMap { model -> OpenRouterModelOption? in
            guard let modelID = model.id.nilIfEmpty else { return nil }
            let modalities = normalizedInputModalities(from: model.architecture)
            return OpenRouterModelOption(
                id: modelID,
                name: model.name?.nilIfEmpty,
                inputModalities: Array(modalities)
            )
        }
        if options.isEmpty {
            throw NSError(
                domain: "OpenRouterModels",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No models returned from \(modelsURL.absoluteString)."]
            )
        }

        return options.sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private static func normalizedInputModalities(from architecture: OpenRouterModelArchitecture?) -> Set<String> {
        var output = Set<String>()
        for modality in architecture?.inputModalities ?? [] {
            if let normalized = modality.nilIfEmpty?.lowercased() {
                output.insert(normalized)
            }
        }

        if output.isEmpty, let modality = architecture?.modality?.lowercased() {
            let inputPart = modality.components(separatedBy: "->").first ?? modality
            let components = inputPart
                .split(separator: "+")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            for component in components where !component.isEmpty {
                output.insert(component)
            }
        }

        return output
    }

    private static func modelsURL(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }

        var path = components.path
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        } else if path.hasSuffix("/completions") {
            path.removeLast("/completions".count)
        } else if path.hasSuffix("/") {
            path.removeLast()
        } else if let slash = path.lastIndex(of: "/"), slash > path.startIndex {
            path = String(path[..<slash])
        } else {
            path = ""
        }

        let normalizedPrefix = path.hasSuffix("/") ? path : path + "/"
        components.path = normalizedPrefix + "models"
        components.queryItems = [URLQueryItem(name: "output_modality", value: "all")]
        components.fragment = nil
        return components.url ?? endpoint
    }

    private struct OpenRouterModelListResponse: Decodable {
        let data: [OpenRouterModel]
    }

    private struct OpenRouterModel: Decodable {
        let id: String
        let name: String?
        let architecture: OpenRouterModelArchitecture?
    }

    private struct OpenRouterModelArchitecture: Decodable {
        let modality: String?
        let inputModalities: [String]?

        private enum CodingKeys: String, CodingKey {
            case modality
            case inputModalities = "input_modalities"
        }
    }
}

struct ActivityDashboardView: View {
    @ObservedObject var store: ActivityDashboardStore

    private var filteredAppRows: [DashboardDayAppRow] {
        let needle = store.appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.dayAppRows }
        return store.dayAppRows.filter { row in
            row.appName.lowercased().contains(needle) || (row.bundleID?.lowercased().contains(needle) ?? false)
        }
    }

    private var selectedDayUsage: TimeInterval {
        store.dayAppRows.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial)

            Divider()

            contentBody
                .padding(10)
        }
        .overlay(alignment: .center) {
            if store.isQuitFinalizing {
                QuitFinalizationOverlay()
            }
        }
        .sheet(isPresented: $store.isSettingsPresented) {
            SettingsView(store: store)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                if store.isRecording {
                    store.stopRecording()
                } else {
                    store.startRecording()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(store.isTranscriptRunning ? "Stop Transcript" : "Start Transcript") {
                if store.isTranscriptRunning {
                    store.stopTranscript()
                } else {
                    store.startTranscript()
                }
            }
            .disabled(!store.isRecording)

            if store.isTranscriptRunning {
                Label("Transcript \(store.transcriptElapsedText)", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
            }

            DatePicker("Day", selection: $store.selectedDay, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 132)

            Spacer()

            Button {
                store.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                store.closeDashboard()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .controlSize(.regular)
    }

    private var contentBody: some View {
        HStack(alignment: .top, spacing: 12) {
            askMeAnythingColumn
                .frame(width: 340)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                usageOverviewCard
                appsListCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()

            appDetailsPanel
                .frame(width: 390)
        }
    }

    private var usageOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App & Website Activity")
                        .font(.headline.weight(.semibold))
                    Text("Updated \(timeText(Date(), format: "HH:mm"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(dayText(store.selectedDay))
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Usage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(durationCompact(selectedDayUsage))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text(store.selectedRangeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            WeekUsageStrip(
                items: store.weekUsage,
                selectedDay: store.selectedDay,
                onSelect: { store.selectDay($0) }
            )

            HourlyUsageBars(
                items: store.hourlyUsage,
                selectedHour: store.selectedHour,
                onSelectHour: { store.selectHour($0) }
            )
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var appsListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Show Apps")
                    .font(.headline.weight(.semibold))
                Spacer()
                if store.selectedHour != nil {
                    Button("All Day") {
                        store.clearHourSelection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                TextField("Search", text: $store.appSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Text("Scope: \(store.selectedRangeTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Apps")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Time")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(filteredAppRows) { row in
                        Button {
                            store.selectDayApp(row)
                        } label: {
                            DayAppListRowView(
                                row: row,
                                isSelected: row.id == store.selectedDayAppRow?.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if filteredAppRows.isEmpty {
                Text("No apps match your search for this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var appDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Activity Log")
                .font(.headline)

            if let selected = store.selectedDayAppRow {
                Text("\(selected.appName) • \(dayText(store.selectedDay)) • \(store.selectedRangeTitle) • \(durationText(selected.duration))")
                    .font(.subheadline.weight(.semibold))

                if store.evidenceDetails.isEmpty {
                    Text(store.selectedHour == nil
                         ? "No analyzed evidence for this app on this day yet."
                         : "No analyzed evidence for this app in this hour yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.evidenceDetails) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(timeText(item.timestamp)) • \(item.kind.rawValue)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(item.description)
                                        .font(.system(size: 13))
                                    if let problem = item.problem?.nilIfEmpty {
                                        Text("Problem: \(problem)")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.red)
                                    }
                                    if let success = item.success?.nilIfEmpty {
                                        Text("Success: \(success)")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.green)
                                    }
                                    if let contribution = item.userContribution?.nilIfEmpty {
                                        Text("Contribution: \(contribution)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let suggestion = item.suggestionOrDecision?.nilIfEmpty {
                                        Text("Suggestion/Decision: \(suggestion)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    if item.status != .none {
                                        Text("Status: \(artifactStatusText(item.status)) • confidence \(item.confidence, specifier: "%.2f")")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let project = item.project?.nilIfEmpty {
                                        Text("Project: \(project)")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let workspace = item.workspace?.nilIfEmpty {
                                        Text("Workspace: \(workspace)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let task = item.task?.nilIfEmpty {
                                        Text("Working on: \(task)")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    if let transcript = item.transcript, !transcript.isEmpty {
                                        Text(transcript)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    if !item.evidence.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(Array(item.evidence.prefix(4).enumerated()), id: \.offset) { _, fact in
                                                Text("• \(fact)")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    if !item.entities.isEmpty {
                                        Text(item.entities.joined(separator: ", "))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            } else {
                Text(store.selectedHour == nil
                     ? "Select an app from the list to view a chronological log of screenshot descriptions for the day."
                     : "Select an app from the list to view a chronological log of screenshot descriptions for the selected hour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var askMeAnythingColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Me Anything")
                .font(.title3.weight(.semibold))

            HStack {
                TextField("What did I forget this week? / When did I work on X?", text: $store.memoryQueryText)
                    .textFieldStyle(.roundedBorder)
                Button(store.isMemoryQueryLoading ? "Asking..." : "Ask") {
                    store.runMemoryQuery()
                }
                .disabled(!canRunQuery)
            }
            .controlSize(.regular)

            ScrollView {
                if store.isMemoryQueryLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Querying memory...")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let memoryQueryError = store.memoryQueryError {
                    Text(memoryQueryError)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.memoryQueryResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ask a natural-language question to query your memory history.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(store.memoryQueryResult)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var canRunQuery: Bool {
        !store.memoryQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isMemoryQueryLoading
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%dm %02ds", minutes, seconds)
    }

    private func durationCompact(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func timeText(_ date: Date, format: String = "HH:mm:ss") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    private func artifactStatusText(_ status: ArtifactInferenceStatus) -> String {
        switch status {
        case .none:
            return "none"
        case .blocked:
            return "blocked"
        case .inProgress:
            return "in_progress"
        case .resolved:
            return "resolved"
        }
    }
}

struct WeekUsageStrip: View {
    let items: [DashboardWeekdayUsage]
    let selectedDay: Date
    let onSelect: (Date) -> Void

    var body: some View {
        let maxDuration = max(items.map(\.duration).max() ?? 1, 1)

        return GeometryReader { proxy in
            let slotCount = max(items.count, 1)
            let slotWidth = proxy.size.width / CGFloat(slotCount)

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let isSelected = Calendar.autoupdatingCurrent.isDate(item.day, inSameDayAs: selectedDay)
                    let barHeight = max(5, (proxy.size.height - 18) * (item.duration / maxDuration))

                    Button {
                        onSelect(item.day)
                    } label: {
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: max(14, slotWidth * 0.45), height: barHeight)
                            Text(shortWeekday(item.day))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .frame(width: slotWidth, height: proxy.size.height)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 70)
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date).uppercased()
    }
}

struct HourlyUsageBars: View {
    let items: [DashboardHourUsage]
    let selectedHour: Int?
    let onSelectHour: (Int) -> Void

    var body: some View {
        let maxDuration = max(items.map(\.duration).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let slotCount = max(items.count, 1)
                let slotWidth = proxy.size.width / CGFloat(slotCount)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        let isSelected = selectedHour == nil || selectedHour == item.hour
                        let hasUsage = item.duration > 0
                        let fillColor: Color = isSelected
                            ? Color.accentColor.opacity(hasUsage ? 0.90 : 0.22)
                            : Color.secondary.opacity(0.18)

                        Button {
                            onSelectHour(item.hour)
                        } label: {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(fillColor)
                                    .frame(
                                        width: max(4, slotWidth - 2),
                                        height: max(2, (proxy.size.height - 2) * (item.duration / maxDuration))
                                    )
                            }
                            .frame(width: slotWidth, height: proxy.size.height)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(format: "%02d:00 • %dm", item.hour, Int(item.duration / 60)))
                    }
                }
            }
            .frame(height: 62)

            HStack {
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("24")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct DayAppListRowView: View {
    let row: DashboardDayAppRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }

            Text(row.appName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            Text(durationCompact(row.duration))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color(NSColor.controlBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func durationCompact(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct SettingsView: View {
    @ObservedObject var store: ActivityDashboardStore
    @State private var apiKeyDraft = ""
    @State private var userAliasesDraft = ""
    @State private var isModelPickerPresented = false
    @State private var modelSearchText = ""
    @State private var activeModelPickerSlot: ModelPickerSlot = .multimodal

    private enum ModelPickerSlot: String {
        case multimodal
        case audio
        case text

        var title: String {
            switch self {
            case .multimodal:
                return "Multimodal"
            case .audio:
                return "Audio"
            case .text:
                return "Text"
            }
        }

        var requiredInputModalities: Set<String>? {
            switch self {
            case .multimodal:
                return ["image", "audio", "video"]
            case .audio:
                return ["audio"]
            case .text:
                return nil
            }
        }
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 0) {
                HStack {
                    Button("← Back to App") {
                        store.isSettingsPresented = false
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial)

                Divider()

                Form {
                    Section("OpenRouter") {
                        SecureField("OPENROUTER_API_KEY", text: $apiKeyDraft)
                        openRouterModelSelectors
                        if let modelError = store.openRouterModelsError {
                            Text(modelError)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        Text("Default model for all modes: \(AppSettings.defaultOpenRouterModel).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        LabeledContent("Today") {
                            Text("\(store.usageToday.requestCount) calls • in \(store.usageToday.inputTokens) • out \(store.usageToday.outputTokens) • audio \(store.usageToday.audioTokens) • $\(store.usageToday.estimatedCostUSD, specifier: "%.4f")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("All Time") {
                            Text("\(store.usageAllTime.requestCount) calls • in \(store.usageAllTime.inputTokens) • out \(store.usageAllTime.outputTokens) • audio \(store.usageAllTime.audioTokens) • $\(store.usageAllTime.estimatedCostUSD, specifier: "%.4f")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Capture") {
                        Toggle("Capture screenshots (activation+3s, then every 30s)", isOn: $store.settingsDraft.captureScreenshots)
                        Toggle("Enable transcript controls", isOn: $store.settingsDraft.transcriptControlsEnabled)
                        Toggle("Require consent before Start Transcript", isOn: $store.settingsDraft.requireTranscriptConsent)
                        Toggle("Track Agent Context app windows", isOn: $store.settingsDraft.includeSelfAppInTracking)
                    }

                    Section("Memory") {
                        Toggle("Enable Mem0 ingestion", isOn: $store.settingsDraft.mem0Enabled)
                        TextField("Mem0 user id", text: $store.settingsDraft.mem0UserID)
                        TextField("Mem0 agent id", text: $store.settingsDraft.mem0AgentID)
                        TextField("Mem0 collection", text: $store.settingsDraft.mem0Collection)
                        TextField("Your work/chat names (comma-separated)", text: $userAliasesDraft)
                        Text("Use names/handles you appear under at work or in chats (for example: full name, Slack display name, username).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Section("Update") {
                        if store.isCheckingForUpdates {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking origin/main...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } else if let status = store.updateStatus {
                            LabeledContent("Branch") {
                                Text(status.branch)
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            LabeledContent("Local") {
                                Text(shortCommit(status.localCommit))
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            LabeledContent("origin/main") {
                                Text(shortCommit(status.remoteCommit))
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            Text(updateRelationshipText(status))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(status.relationship == .behind ? .orange : .secondary)
                            if status.isWorkingTreeDirty {
                                Text("Uncommitted local changes detected. Commit or stash before updating.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Check against GitHub main branch before updating.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button(store.isCheckingForUpdates ? "Checking..." : "Check for Updates") {
                                store.checkForAppUpdate()
                            }
                            .disabled(store.isCheckingForUpdates || store.isApplyingUpdate)

                            Button(store.isApplyingUpdate ? "Updating..." : "Update, Rebuild, and Restart") {
                                store.applyAppUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canApplyUpdate)
                        }

                        Text("Update flow: fetch origin/main, fast-forward pull, rebuild, then relaunch.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Section("App") {
                        Button("Quit Agent Context", role: .destructive) {
                            store.requestQuit()
                        }
                        .disabled(store.isApplyingUpdate || store.isQuitFinalizing)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let message = store.settingsMessage {
                            Text(message)
                                .foregroundStyle(.green)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        if let error = store.settingsError {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        if let updateMessage = store.updateMessage {
                            Text(updateMessage)
                                .foregroundStyle(.green)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        if let updateError = store.updateError {
                            Text(updateError)
                                .foregroundStyle(.red)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Spacer()

                        Button("Save") {
                            store.settingsDraft.openRouterAPIKey = apiKeyDraft.nilIfEmpty
                            store.settingsDraft.openRouterModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterModel)
                            store.settingsDraft.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterAudioModel)
                            store.settingsDraft.openRouterTextModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterTextModel)
                            store.settingsDraft.userIdentityAliases = AppSettings.parseAliases(from: userAliasesDraft)
                            store.saveSettings()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.isQuitFinalizing)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(10)
        .frame(width: 760, height: 640)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            apiKeyDraft = store.settingsDraft.openRouterAPIKey ?? ""
            store.settingsDraft.openRouterModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterModel)
            store.settingsDraft.openRouterAudioModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterAudioModel)
            store.settingsDraft.openRouterTextModel = AppSettings.normalizedOpenRouterModel(store.settingsDraft.openRouterTextModel)
            modelSearchText = ""
            userAliasesDraft = AppSettings.aliasesText(store.settingsDraft.userIdentityAliases)
        }
    }

    private var openRouterModelSelectors: some View {
        VStack(spacing: 8) {
            modelSelectorRow(label: "Multimodal model", slot: .multimodal)
            modelSelectorRow(label: "Audio model", slot: .audio)
            modelSelectorRow(label: "Text model", slot: .text)
            HStack {
                Spacer()
                Button {
                    store.settingsDraft.openRouterAPIKey = apiKeyDraft.nilIfEmpty
                    store.refreshOpenRouterModels(force: true)
                } label: {
                    if store.isLoadingOpenRouterModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func modelSelectorRow(label: String, slot: ModelPickerSlot) -> some View {
        LabeledContent(label) {
                Button {
                    store.settingsDraft.openRouterAPIKey = apiKeyDraft.nilIfEmpty
                    activeModelPickerSlot = slot
                    modelSearchText = ""
                    isModelPickerPresented = true
                    store.refreshOpenRouterModels(force: store.availableOpenRouterModels.isEmpty)
                } label: {
                HStack(spacing: 6) {
                    Text(currentModel(for: slot))
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: popoverBinding(for: slot), arrowEdge: .bottom) {
                openRouterModelPopover
            }
        }
    }

    private var openRouterModelPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose \(activeModelPickerSlot.title) Model")
                .font(.system(size: 14, weight: .semibold))

            TextField("Quick search model id", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)

            if store.isLoadingOpenRouterModels {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading from /models...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredOpenRouterModels) { model in
                        Button {
                            selectModel(model.id)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.id)
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if !model.inputModalities.isEmpty {
                                        Text(model.inputModalities.sorted().joined(separator: ", "))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if model.id == currentModel(for: activeModelPickerSlot) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if let customModelCandidate {
                        if !filteredOpenRouterModels.isEmpty {
                            Divider().padding(.vertical, 4)
                        }
                        Button {
                            selectModel(customModelCandidate)
                        } label: {
                            HStack(spacing: 8) {
                                Text("Use \"\(customModelCandidate)\"")
                                    .font(.system(size: 14))
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredOpenRouterModels.isEmpty && customModelCandidate == nil {
                        Text("No models match your search.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 440)
        .padding(12)
    }

    private var canApplyUpdate: Bool {
        guard !store.isCheckingForUpdates, !store.isApplyingUpdate else {
            return false
        }

        guard let status = store.updateStatus else {
            return true
        }

        return status.relationship == .behind && !status.isWorkingTreeDirty && status.branch == "main"
    }

    private func shortCommit(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func updateRelationshipText(_ status: AppUpdateStatus) -> String {
        switch status.relationship {
        case .upToDate:
            return "Already up to date."
        case .behind:
            return "Update available."
        case .ahead:
            return "Local branch is ahead of origin/main."
        case .diverged:
            return "Local branch has diverged from origin/main."
        }
    }

    private var filteredOpenRouterModels: [OpenRouterModelOption] {
        let needle = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.availableOpenRouterModels }
        return store.availableOpenRouterModels.filter { model in
            model.id.lowercased().contains(needle)
                || (model.name?.lowercased().contains(needle) ?? false)
        }
    }

    private var customModelCandidate: String? {
        guard let typed = modelSearchText.nilIfEmpty else { return nil }
        let normalized = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = store.availableOpenRouterModels.contains { model in
            model.id.caseInsensitiveCompare(normalized) == .orderedSame
        }
        return exists ? nil : normalized
    }

    private func currentModel(for slot: ModelPickerSlot) -> String {
        switch slot {
        case .multimodal:
            return store.settingsDraft.openRouterModel
        case .audio:
            return store.settingsDraft.openRouterAudioModel
        case .text:
            return store.settingsDraft.openRouterTextModel
        }
    }

    private func selectModel(_ model: String) {
        let normalizedModel = AppSettings.normalizedOpenRouterModel(model)
        switch activeModelPickerSlot {
        case .multimodal:
            store.settingsDraft.openRouterModel = normalizedModel
        case .audio:
            store.settingsDraft.openRouterAudioModel = normalizedModel
        case .text:
            store.settingsDraft.openRouterTextModel = normalizedModel
        }
        modelSearchText = normalizedModel
        isModelPickerPresented = false
    }

    private func popoverBinding(for slot: ModelPickerSlot) -> Binding<Bool> {
        Binding(
            get: { isModelPickerPresented && activeModelPickerSlot == slot },
            set: { presented in
                if !presented {
                    isModelPickerPresented = false
                }
            }
        )
    }
}

struct QuitFinalizationOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Finalizing pending analysis and summaries before quit...")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }
}
