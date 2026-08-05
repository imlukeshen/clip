import CoreGraphics
import CoreModel
import Foundation
import ImageIO
@preconcurrency import Vision

/// One Vision text observation in normalized image coordinates.
public struct RecognizedTextBlock: Sendable, Equatable {
    public var text: String
    public var boundingBox: CoreModel.NormalizedRect
    public var confidence: Double
    public var script: OCRScript

    public init(
        text: String,
        boundingBox: CoreModel.NormalizedRect,
        confidence: Double,
        script: OCRScript? = nil
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.script = script ?? OCRScriptDetector.detect(in: text)
    }
}

/// On-device OCR configured for small, text-dense screen content.
public struct VisionTextRecognizer: Sendable {
    public static let revision = VNRecognizeTextRequestRevision3

    public init() {}

    public func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        usesLanguageCorrection: Bool = true
    ) async throws -> [RecognizedTextBlock] {
        try await Task.detached(priority: .background) {
            try Self.performRecognition(
                image,
                orientation: orientation,
                usesLanguageCorrection: usesLanguageCorrection
            )
        }.value
    }

    private static func performRecognition(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        usesLanguageCorrection: Bool
    ) throws -> [RecognizedTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.minimumTextHeight = 0.008
        request.recognitionLanguages = Locale.preferredLanguages
        request.revision = Self.revision
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])
        var blocks: [RecognizedTextBlock] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                candidate.confidence > 0.3
            else { continue }
            let box = observation.boundingBox
            blocks.append(
                RecognizedTextBlock(
                    text: candidate.string,
                    boundingBox: CoreModel.NormalizedRect(
                        x: box.minX,
                        y: box.minY,
                        width: box.width,
                        height: box.height
                    ),
                    confidence: Double(candidate.confidence)
                )
            )
        }
        return blocks.sorted {
            abs($0.boundingBox.y - $1.boundingBox.y) < 0.015
                ? $0.boundingBox.x < $1.boundingBox.x
                : $0.boundingBox.y > $1.boundingBox.y
        }
    }
}

/// Script routing for Unicode61 versus trigram FTS indexes.
public enum OCRScriptDetector {
    public static func detect(in text: String) -> OCRScript {
        var hasCJK = false
        var hasAlphabetic = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar.value) {
                hasCJK = true
            } else if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
            {
                hasAlphabetic = true
            }
        }
        if hasCJK, hasAlphabetic { return .mixed }
        return hasCJK ? .cjk : .alphabetic
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF,
            0x0E00...0x0E7F:
            true
        default:
            false
        }
    }
}
