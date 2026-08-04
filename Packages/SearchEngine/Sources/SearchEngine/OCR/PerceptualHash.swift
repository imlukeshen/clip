import CoreGraphics
import Foundation

/// A compact 32×32 grayscale average hash used to detect changed screens.
public struct PerceptualHash: Sendable, Equatable {
    public static let bitCount = 1_024
    private var words: [UInt64]

    public init(words: [UInt64]) {
        precondition(words.count == Self.bitCount / UInt64.bitWidth)
        self.words = words
    }

    public init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.bitCount)
        guard
            let context = CGContext(
                data: &pixels,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var words = [UInt64](repeating: 0, count: Self.bitCount / UInt64.bitWidth)
        for (index, pixel) in pixels.enumerated() where Int(pixel) >= average {
            words[index / UInt64.bitWidth] |= UInt64(1) << UInt64(index % UInt64.bitWidth)
        }
        self.words = words
    }

    public func hammingDistance(to other: Self) -> Int {
        zip(words, other.words).reduce(0) { partial, pair in
            partial + (pair.0 ^ pair.1).nonzeroBitCount
        }
    }
}

/// Pure sampling rules shared by the AVAssetReader implementation and tests.
public enum OCRFrameSelectionPolicy {
    public static let samplesPerMinute = 12
    public static let maximumFramesPerAsset = 400
    public static let changeThreshold = Int(Double(PerceptualHash.bitCount) * 0.08)

    public static func bucketDuration(for assetDuration: Double) -> Double {
        max(60 / Double(samplesPerMinute), assetDuration / Double(maximumFramesPerAsset))
    }

    public static func shouldAccept(
        hash: PerceptualHash,
        after previous: PerceptualHash?,
        isFirstFrame: Bool,
        isClickAnchor: Bool
    ) -> Bool {
        isFirstFrame || isClickAnchor
            || previous.map { hash.hammingDistance(to: $0) >= changeThreshold } == true
    }
}
