import CoreModel
import Foundation

/// OCR regions arranged the way a person reads them on the rendered frame.
public struct LiveTextFrame: Sendable, Equatable {
    public let spans: [OCRSpan]

    public init(spans: [OCRSpan]) {
        self.spans = spans.sorted { lhs, rhs in
            let verticalDistance = abs(lhs.boundingBox.y - rhs.boundingBox.y)
            if verticalDistance < 0.015 {
                return lhs.boundingBox.x < rhs.boundingBox.x
            }
            return lhs.boundingBox.y > rhs.boundingBox.y
        }
    }

    public var allText: String {
        spans.map(\.text).joined(separator: "\n")
    }

    public func text(in range: ClosedRange<Int>) -> String {
        guard !spans.isEmpty else { return "" }
        let lower = min(
            max(range.lowerBound, spans.startIndex), spans.index(before: spans.endIndex))
        let upper = min(max(range.upperBound, lower), spans.index(before: spans.endIndex))
        return spans[lower...upper].map(\.text).joined(separator: "\n")
    }

    public func regions(in range: ClosedRange<Int>) -> [NormalizedRect] {
        guard !spans.isEmpty else { return [] }
        let lower = min(
            max(range.lowerBound, spans.startIndex), spans.index(before: spans.endIndex))
        let upper = min(max(range.upperBound, lower), spans.index(before: spans.endIndex))
        return spans[lower...upper].map(\.boundingBox)
    }

    /// Converts Vision's bottom-left normalized coordinates to Clip's top-left canvas space.
    public static func canvasRect(for visionRect: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: visionRect.x,
            y: 1 - visionRect.y - visionRect.height,
            width: visionRect.width,
            height: visionRect.height
        )
    }
}

public enum LiveTextDetectedValue: Sendable, Equatable {
    case url(URL)
    case email(String)
    case sensitive
}

/// Small, deterministic detectors used to add useful actions to a Live Text selection.
public enum LiveTextDetector {
    public static func values(in text: String) -> [LiveTextDetectedValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var values: [LiveTextDetectedValue] = []

        if let match = firstMatch(#"https?://[^\s<>]+"#, in: trimmed),
            let url = URL(string: match)
        {
            values.append(.url(url))
        }
        if let email = firstMatch(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: trimmed,
            options: [.caseInsensitive]
        ) {
            values.append(.email(email))
        }
        if secretPatterns.contains(where: { firstMatch($0, in: trimmed) != nil }) {
            values.append(.sensitive)
        }
        return values
    }

    private static let secretPatterns = [
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        #"\b(?:api[_-]?key|token|secret)\s*[:=]\s*[^\s]{8,}\b"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
    ]

    private static func firstMatch(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
            let swiftRange = Range(match.range, in: text)
        else { return nil }
        return String(text[swiftRange])
    }
}
