import Foundation

enum ArtifactKind: String, Codable, Hashable {
    case screenshot
    case audio
}

struct WindowContext: Codable, Sendable {
    let title: String?
    let documentPath: String?
    let url: String?
    let workspace: String?
    let project: String?
}

struct AppDescriptor: Codable, Sendable, Hashable {
    let appName: String
    let bundleID: String?
    let pid: Int32
}

struct ActivityInterval: Codable, Sendable, Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date
    let app: AppDescriptor
    let window: WindowContext

    var duration: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }

    var appKey: String {
        if let bundleID = app.bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return app.appName
    }
}

struct ArtifactMetadata: Codable, Sendable {
    let id: String
    let kind: ArtifactKind
    let path: String
    let capturedAt: Date
    let app: AppDescriptor
    let window: WindowContext
    let intervalID: String?
    let captureReason: String
    let sequenceInInterval: Int
}
