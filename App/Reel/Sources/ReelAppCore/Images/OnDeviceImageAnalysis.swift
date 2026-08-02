import AIKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

public enum RedactionSuggestionKind: String, Codable, Sendable, Equatable {
    case email
    case credential
    case ipAddress
    case face
}

public struct RedactionSuggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RedactionSuggestionKind
    public var region: CGRect
    public var confidence: Double
    public var preview: String

    public init(
        id: String,
        kind: RedactionSuggestionKind,
        region: CGRect,
        confidence: Double,
        preview: String
    ) {
        self.id = id
        self.kind = kind
        self.region = region
        self.confidence = confidence
        self.preview = preview
    }
}

/// Vision-only sensitive-region detection. It has no provider or ledger dependency by design.
public struct OnDeviceRedactionSuggester: Sendable {
    public init() {}

    public func suggestions(in imageURL: URL) async throws -> [RedactionSuggestion] {
        try await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = false
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            try handler.perform([textRequest, faceRequest])

            var suggestions: [RedactionSuggestion] = []
            for (index, observation) in (textRequest.results ?? []).enumerated() {
                guard let candidate = observation.topCandidates(1).first,
                    let kind = sensitiveKind(in: candidate.string)
                else { continue }
                let region = observation.boundingBox.topLeftNormalized
                suggestions.append(
                    RedactionSuggestion(
                        id: identifier(kind: kind, region: region, index: index),
                        kind: kind,
                        region: region,
                        confidence: Double(candidate.confidence),
                        preview: redactedPreview(candidate.string)
                    )
                )
            }
            let textCount = suggestions.count
            for (index, observation) in (faceRequest.results ?? []).enumerated() {
                let region = observation.boundingBox.topLeftNormalized
                suggestions.append(
                    RedactionSuggestion(
                        id: identifier(kind: .face, region: region, index: textCount + index),
                        kind: .face,
                        region: region,
                        confidence: Double(observation.confidence),
                        preview: "Face"
                    )
                )
            }
            return suggestions.sorted {
                $0.region.minY == $1.region.minY
                    ? $0.region.minX < $1.region.minX : $0.region.minY < $1.region.minY
            }
        }.value
    }
}

public struct OnDeviceAltTextGenerator: Sendable {
    public init() {}

    public func generate(for imageURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            try handler.perform([request])
            let labels = (request.results ?? [])
                .filter { $0.confidence >= 0.15 }
                .prefix(3)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            guard !labels.isEmpty else { return "Image" }
            return "Image containing " + labels.joined(separator: ", ") + "."
        }.value
    }
}

private func sensitiveKind(in text: String) -> RedactionSuggestionKind? {
    let patterns: [(String, RedactionSuggestionKind)] = [
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, .email),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, .ipAddress),
        (#"(?i)\b(?:sk-[A-Z0-9]{12,}|AKIA[A-Z0-9]{16}|(?:api[_-]?key|token|secret)\s*[:=]\s*\S+)\b"#, .credential),
    ]
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for (pattern, kind) in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern),
            regex.firstMatch(in: text, range: range) != nil
        {
            return kind
        }
    }
    return nil
}

private func redactedPreview(_ text: String) -> String {
    guard text.count > 4 else { return String(repeating: "•", count: text.count) }
    return String(text.prefix(2)) + String(repeating: "•", count: min(text.count - 4, 12))
        + String(text.suffix(2))
}

private func identifier(
    kind: RedactionSuggestionKind,
    region: CGRect,
    index: Int
) -> String {
    let values = [region.minX, region.minY, region.width, region.height]
        .map { String(Int(($0 * 10_000).rounded())) }
        .joined(separator: "-")
    return "\(kind.rawValue)-\(values)-\(index)"
}

extension CGRect {
    fileprivate var topLeftNormalized: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }
}
