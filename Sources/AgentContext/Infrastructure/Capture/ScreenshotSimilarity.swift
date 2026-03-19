import Foundation
import CoreGraphics
import ImageIO

struct ScreenshotFingerprint: Sendable {
    let size: Int
    let grayscalePixels: [UInt8]
}

enum ScreenshotSimilarity {
    static func fingerprint(forImageAtPath path: String, size: Int = 32) -> ScreenshotFingerprint? {
        let url = URL(fileURLWithPath: path)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else {
            return nil
        }

        let normalizedSize = max(8, min(128, size))
        let pixelCount = normalizedSize * normalizedSize
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        let bytesPerRow = normalizedSize
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: normalizedSize,
                height: normalizedSize,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: normalizedSize, height: normalizedSize))
            return true
        }

        guard drewImage else { return nil }
        return ScreenshotFingerprint(size: normalizedSize, grayscalePixels: pixels)
    }

    static func similarity(_ lhs: ScreenshotFingerprint, _ rhs: ScreenshotFingerprint) -> Double {
        guard lhs.size == rhs.size, lhs.grayscalePixels.count == rhs.grayscalePixels.count else {
            return 0
        }
        guard !lhs.grayscalePixels.isEmpty else { return 0 }

        var totalAbsoluteDifference = 0
        for index in lhs.grayscalePixels.indices {
            let left = Int(lhs.grayscalePixels[index])
            let right = Int(rhs.grayscalePixels[index])
            totalAbsoluteDifference += abs(left - right)
        }

        let maxDifference = lhs.grayscalePixels.count * 255
        let normalizedDifference = Double(totalAbsoluteDifference) / Double(maxDifference)
        return max(0, min(1, 1 - normalizedDifference))
    }
}
