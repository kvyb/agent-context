import Foundation
import AppKit

struct DashboardHourRow: Identifiable, Sendable {
    let id: Int
    let hour: Int
    let blocks: [DashboardHourAppBlock]
}

struct DashboardHourAppBlock: Identifiable, Sendable {
    let id: String
    let hourStart: Date
    let hourEnd: Date
    let appName: String
    let bundleID: String?
    let duration: TimeInterval
    let icon: NSImage?
}

struct DashboardDayAppRow: Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleID: String?
    let duration: TimeInterval
    let icon: NSImage?
}

struct DashboardHourUsage: Identifiable, Sendable {
    let id: Int
    let hour: Int
    let duration: TimeInterval
}

struct DashboardWeekdayUsage: Identifiable, Sendable {
    let id: String
    let day: Date
    let duration: TimeInterval
}

struct EvidenceDetailItem: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let kind: ArtifactKind
    let appName: String
    let description: String
    let contentDescription: String
    let layoutDescription: String
    let problem: String?
    let success: String?
    let userContribution: String?
    let suggestionOrDecision: String?
    let status: ArtifactInferenceStatus
    let confidence: Double
    let summary: String
    let transcript: String?
    let salientText: [String]
    let uiElements: [ArtifactUIElement]
    let entities: [String]
    let project: String?
    let workspace: String?
    let task: String?
    let evidence: [String]
}
