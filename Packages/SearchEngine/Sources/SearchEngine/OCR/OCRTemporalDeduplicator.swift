import CoreModel
import Foundation

/// OCR output associated with one representative video frame.
public struct OCRFrame: Sendable, Equatable {
    public var time: RationalTime
    public var end: RationalTime
    public var blocks: [RecognizedTextBlock]

    public init(time: RationalTime, end: RationalTime, blocks: [RecognizedTextBlock]) {
        self.time = time
        self.end = end
        self.blocks = blocks
    }
}

/// Collapses a static screen into time-ranged rows instead of one row per sample.
public enum OCRTemporalDeduplicator {
    public static func spans(
        assetID: AssetID,
        frames: [OCRFrame],
        revision: Int,
        similarityThreshold: Double = 0.9
    ) -> [OCRSpan] {
        var result: [OCRSpan] = []
        var activeRange: Range<Int>?
        var activeTokens: Set<String> = []

        for frame in frames where !frame.blocks.isEmpty {
            let tokens = normalizedTokens(in: frame.blocks.map(\.text).joined(separator: " "))
            if let activeRange,
                jaccard(activeTokens, tokens) >= similarityThreshold
            {
                for index in activeRange {
                    result[index].end = max(result[index].end ?? frame.end, frame.end)
                    result[index].confidence = max(
                        result[index].confidence,
                        frame.blocks.map(\.confidence).max() ?? 0
                    )
                }
                continue
            }

            let startIndex = result.count
            result.append(
                contentsOf: frame.blocks.map { block in
                    OCRSpan(
                        assetID: assetID,
                        start: frame.time,
                        end: frame.end,
                        text: block.text,
                        boundingBox: block.boundingBox,
                        confidence: block.confidence,
                        revision: revision,
                        script: block.script
                    )
                }
            )
            activeRange = startIndex..<result.count
            activeTokens = tokens
        }
        return result
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        jaccard(normalizedTokens(in: lhs), normalizedTokens(in: rhs))
    }

    private static func normalizedTokens(in text: String) -> Set<String> {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        var tokens = Set(
            normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let cjk = normalized.unicodeScalars.filter {
            OCRScriptDetector.detect(in: String($0)) == .cjk
        }
        if !cjk.isEmpty {
            let scalars = cjk.map(String.init)
            if scalars.count < 3 {
                tokens.formUnion(scalars)
            } else {
                for index in 0...(scalars.count - 3) {
                    tokens.insert(scalars[index...index + 2].joined())
                }
            }
        }
        return tokens
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty, rhs.isEmpty { return 1 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }
}
