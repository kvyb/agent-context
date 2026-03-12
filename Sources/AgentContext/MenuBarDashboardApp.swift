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
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
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
    @Published var usageToday = LLMUsageTotals()
    @Published var usageAllTime = LLMUsageTotals()

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
        isSettingsPresented = true
    }

    func saveSettings() {
        do {
            try runtime.saveSettings(settingsDraft)
            settingsMessage = "Settings saved"
            settingsError = nil
            refreshDashboard()
        } catch {
            settingsError = error.localizedDescription
            settingsMessage = nil
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
        isQuitFinalizing = true

        Task {
            runtime.stopRecording(finalizePendingWork: true)
            await MainActor.run {
                isQuitFinalizing = false
                NSApplication.shared.terminate(nil)
            }
        }
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

    private func elapsedText(from start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
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
                .padding(12)
                .background(.thinMaterial)

            Divider()

            contentBody
                .padding(12)

            Divider()

            memoryQueryPanel
                .padding(12)
                .background(Color(NSColor.windowBackgroundColor))
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
        HStack(spacing: 12) {
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
                .frame(width: 150)

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
    }

    private var contentBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                usageOverviewCard
                appsListCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()

            appDetailsPanel
                .frame(width: 420)
        }
    }

    private var usageOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App & Website Activity")
                        .font(.title3.weight(.bold))
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
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(durationCompact(selectedDayUsage))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
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
        .padding(16)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var appsListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Show Apps")
                    .font(.title3.weight(.semibold))
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
                    .frame(width: 240)
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
        .padding(16)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var appDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
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
    }

    private var memoryQueryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Me Anything")
                .font(.headline)

            HStack {
                TextField("", text: $store.memoryQueryText)
                    .textFieldStyle(.roundedBorder)
                Button(store.isMemoryQueryLoading ? "Asking..." : "Ask") {
                    store.runMemoryQuery()
                }
                .disabled(store.isMemoryQueryLoading)
            }

            ScrollView {
                if store.isMemoryQueryLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Querying memory...")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let memoryQueryError = store.memoryQueryError {
                    Text(memoryQueryError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.memoryQueryResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ask a natural-language question to query your memory history.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(store.memoryQueryResult)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 80, maxHeight: 120)
        }
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
                    let barHeight = max(6, (proxy.size.height - 22) * (item.duration / maxDuration))

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
        .frame(height: 84)
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
            .frame(height: 74)

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
        HStack(spacing: 10) {
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            }

            Text(row.appName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Spacer()

            Text(durationCompact(row.duration))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.title2.weight(.bold))

            GroupBox("OpenRouter") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("OPENROUTER_API_KEY", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Usage Today: \(store.usageToday.requestCount) calls, in \(store.usageToday.inputTokens), out \(store.usageToday.outputTokens), audio \(store.usageToday.audioTokens), $\(store.usageToday.estimatedCostUSD, specifier: "%.4f")")
                            .font(.system(size: 11))
                        Spacer()
                    }
                    HStack {
                        Text("All Time: \(store.usageAllTime.requestCount) calls, in \(store.usageAllTime.inputTokens), out \(store.usageAllTime.outputTokens), audio \(store.usageAllTime.audioTokens), $\(store.usageAllTime.estimatedCostUSD, specifier: "%.4f")")
                            .font(.system(size: 11))
                        Spacer()
                    }
                }
            }

            GroupBox("Capture Policies") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Capture screenshots (activation+3s, then every 30s)", isOn: $store.settingsDraft.captureScreenshots)
                    Toggle("Enable transcript controls", isOn: $store.settingsDraft.transcriptControlsEnabled)
                    Toggle("Require consent confirmation before Start Transcript", isOn: $store.settingsDraft.requireTranscriptConsent)
                    Toggle("Track Agent Context app windows", isOn: $store.settingsDraft.includeSelfAppInTracking)
                }
            }

            GroupBox("Memory") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable Mem0 ingestion", isOn: $store.settingsDraft.mem0Enabled)
                    TextField("Mem0 user id", text: $store.settingsDraft.mem0UserID)
                    TextField("Mem0 agent id", text: $store.settingsDraft.mem0AgentID)
                    TextField("Mem0 collection", text: $store.settingsDraft.mem0Collection)
                    Divider()
                    TextField("Your work/chat names (comma-separated)", text: $userAliasesDraft)
                    Text("Use names/handles you appear under at work or in chats (for example: full name, Slack display name, username).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

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

            HStack {
                Spacer()
                Button("Cancel") {
                    store.isSettingsPresented = false
                }
                Button("Save") {
                    store.settingsDraft.openRouterAPIKey = apiKeyDraft.nilIfEmpty
                    store.settingsDraft.userIdentityAliases = AppSettings.parseAliases(from: userAliasesDraft)
                    store.saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760)
        .onAppear {
            apiKeyDraft = store.settingsDraft.openRouterAPIKey ?? ""
            userAliasesDraft = AppSettings.aliasesText(store.settingsDraft.userIdentityAliases)
        }
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
