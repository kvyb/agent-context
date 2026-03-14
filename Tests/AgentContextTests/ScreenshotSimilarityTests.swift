import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AgentContext

final class ScreenshotSimilarityTests: XCTestCase {
    func testIdenticalImagesHaveNearPerfectSimilarity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")

        try writeSolidImage(path: first.path, gray: 180)
        try writeSolidImage(path: second.path, gray: 180)

        let firstFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: first.path)
        let secondFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: second.path)

        XCTAssertNotNil(firstFingerprint)
        XCTAssertNotNil(secondFingerprint)
        XCTAssertEqual(
            ScreenshotSimilarity.similarity(firstFingerprint!, secondFingerprint!),
            1,
            accuracy: 0.0001
        )
    }

    func testSlightlyDifferentImagesStillCross99Percent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")

        try writeSolidImage(path: first.path, gray: 180)
        try writeSolidImage(path: second.path, gray: 181)

        let firstFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: first.path)!
        let secondFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: second.path)!
        let similarity = ScreenshotSimilarity.similarity(firstFingerprint, secondFingerprint)

        XCTAssertGreaterThanOrEqual(similarity, 0.99)
    }

    func testVeryDifferentImagesAreBelow99Percent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")

        try writeSolidImage(path: first.path, gray: 20)
        try writeSolidImage(path: second.path, gray: 220)

        let firstFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: first.path)!
        let secondFingerprint = ScreenshotSimilarity.fingerprint(forImageAtPath: second.path)!
        let similarity = ScreenshotSimilarity.similarity(firstFingerprint, secondFingerprint)

        XCTAssertLessThan(similarity, 0.99)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSolidImage(path: String, gray: UInt8) throws {
        let width = 32
        let height = 32
        let bytesPerRow = width
        var pixels = [UInt8](repeating: gray, count: width * height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }), let image = context.makeImage() else {
            throw NSError(domain: "ScreenshotSimilarityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to build test image"])
        }

        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ScreenshotSimilarityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ScreenshotSimilarityTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG"])
        }
    }
}
