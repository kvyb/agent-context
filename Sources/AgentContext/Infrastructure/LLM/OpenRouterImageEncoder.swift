import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OpenRouterImageEncoder: Sendable {
    func webPDataForLLM(from imagePath: String) throws -> Data {
        let url = URL(fileURLWithPath: imagePath)
        if url.pathExtension.lowercased() == "webp" {
            return try Data(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "OpenRouterClient",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Unable to decode screenshot for WebP conversion: \(imagePath)"]
            )
        }

        if let nativeWebP = encodeNativeWebP(image: image) {
            return nativeWebP
        }

        if let cwebpData = encodeWebPWithCWebP(image: image) {
            return cwebpData
        }

        throw NSError(
            domain: "OpenRouterClient",
            code: 102,
            userInfo: [NSLocalizedDescriptionKey: "Unable to convert screenshot to WebP for LLM: \(imagePath)"]
        )
    }

    private func encodeNativeWebP(image: CGImage) -> Data? {
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.webP.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    private func encodeWebPWithCWebP(image: CGImage) -> Data? {
        guard let cwebpPath = Self.cwebpPath else { return nil }
        guard let pngData = encodePNG(image: image) else { return nil }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-context-or-webp-\(UUID().uuidString)", isDirectory: true)
        let inputURL = tempDirectory.appendingPathComponent("input.png")
        let outputURL = tempDirectory.appendingPathComponent("output.webp")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            try pngData.write(to: inputURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cwebpPath)
            process.arguments = ["-quiet", "-q", "65", inputURL.path, "-o", outputURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: outputURL)
        } catch {
            return nil
        }
    }

    private func encodePNG(image: CGImage) -> Data? {
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private static let cwebpPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/cwebp",
            "/usr/local/bin/cwebp",
            "/usr/bin/cwebp"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}
