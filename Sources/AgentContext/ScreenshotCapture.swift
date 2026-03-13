import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class ScreenshotCapture: @unchecked Sendable {
    private let config: TrackerConfig
    private let outputDirectory: URL
    private let queue = DispatchQueue(label: "agent-context.screenshot.capture", qos: .utility)
    private static let cwebpPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/cwebp",
            "/usr/local/bin/cwebp",
            "/usr/bin/cwebp"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    init(config: TrackerConfig) throws {
        self.config = config
        outputDirectory = config.screenshotsDirectory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func capture(
        app: AppDescriptor,
        window: WindowContext,
        intervalID: String?,
        sequenceInInterval: Int,
        reason: String,
        completion: @escaping @Sendable (ArtifactMetadata?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            let image: CGImage?
            if let directCapture = CGDisplayCreateImage(CGMainDisplayID()) {
                ScreenCapturePermission.markGrantedBySuccessfulCapture()
                image = directCapture
            } else {
                guard
                    ScreenCapturePermission.isGrantedOrKnownGrantedThisRun()
                        || ScreenCapturePermission.requestIfNeededOnce(),
                    let retriedCapture = CGDisplayCreateImage(CGMainDisplayID())
                else {
                    completion(nil)
                    return
                }
                ScreenCapturePermission.markGrantedBySuccessfulCapture()
                image = retriedCapture
            }

            guard let image else {
                completion(nil)
                return
            }

            let resized = self.resize(image: image, maxDimension: self.config.screenshotMaxDimension) ?? image
            guard let encoded = self.encode(image: resized, quality: self.config.screenshotQuality) else {
                completion(nil)
                return
            }

            let now = Date()
            let fileName = self.makeFileName(date: now, appName: app.appName, reason: reason, extensionName: encoded.extensionName)
            let fileURL = self.outputDirectory.appendingPathComponent(fileName)

            do {
                try encoded.data.write(to: fileURL, options: .atomic)
            } catch {
                completion(nil)
                return
            }

            let metadata = ArtifactMetadata(
                id: UUID().uuidString,
                kind: .screenshot,
                path: fileURL.path,
                capturedAt: now,
                app: app,
                window: window,
                intervalID: intervalID,
                captureReason: reason,
                sequenceInInterval: sequenceInInterval
            )
            completion(metadata)
        }
    }

    private func makeFileName(date: Date, appName: String, reason: String, extensionName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let normalizedApp = sanitize(appName)
        let normalizedReason = sanitize(reason)
        return "\(formatter.string(from: date))-\(normalizedApp)-\(normalizedReason).\(extensionName)"
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") { $0.append($1) }
    }

    private func resize(image: CGImage, maxDimension: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let currentMax = max(width, height)
        guard currentMax > maxDimension else { return image }

        let scale = Double(maxDimension) / Double(currentMax)
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private func encode(image: CGImage, quality: Double) -> (data: Data, extensionName: String)? {
        if let webpData = encode(image: image, type: UTType.webP.identifier, quality: quality) {
            return (webpData, "webp")
        }
        if let cwebpData = encodeWebPWithCWebP(image: image, quality: quality) {
            return (cwebpData, "webp")
        }

        return nil
    }

    private func encode(image: CGImage, type: String, quality: Double) -> Data? {
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(mutableData, type as CFString, 1, nil)
        else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    private func encodeWebPWithCWebP(image: CGImage, quality: Double) -> Data? {
        guard let cwebpPath = Self.cwebpPath else { return nil }
        guard let pngData = encodePNG(image: image) else { return nil }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-context-webp-\(UUID().uuidString)", isDirectory: true)
        let inputURL = tempDirectory.appendingPathComponent("input.png")
        let outputURL = tempDirectory.appendingPathComponent("output.webp")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try pngData.write(to: inputURL, options: .atomic)

            let qualityPercent = max(1, min(100, Int((quality * 100).rounded())))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cwebpPath)
            process.arguments = ["-quiet", "-q", "\(qualityPercent)", inputURL.path, "-o", outputURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: outputURL)
        } catch {
            return nil
        }
    }

    private func encodePNG(image: CGImage) -> Data? {
        encode(image: image, type: UTType.png.identifier, quality: 1.0)
    }
}
