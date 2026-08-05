import CoreModel
import Foundation
import SearchEngine
import Testing

@Suite("Live Text")
struct LiveTextTests {
    @Test("Selection follows visual reading order and preserves exact OCR text")
    func readingOrderSelection() {
        let assetID = AssetID(rawValue: "live-text")
        let frame = LiveTextFrame(
            spans: [
                span("third", x: 0.1, y: 0.4, assetID: assetID),
                span("second", x: 0.6, y: 0.8, assetID: assetID),
                span("first", x: 0.1, y: 0.8, assetID: assetID),
            ]
        )

        #expect(frame.allText == "first\nsecond\nthird")
        #expect(frame.text(in: 1...2) == "second\nthird")
    }

    @Test("Vision regions flip into top-left editor coordinates")
    func coordinateConversion() {
        let rect = LiveTextFrame.canvasRect(
            for: NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.2)
        )

        #expect(abs(rect.x - 0.1) < 0.000_001)
        #expect(abs(rect.y - 0.1) < 0.000_001)
        #expect(abs(rect.width - 0.4) < 0.000_001)
        #expect(abs(rect.height - 0.2) < 0.000_001)
    }

    @Test("Links, email addresses, and secret-like values get contextual actions")
    func dataDetection() {
        let values = LiveTextDetector.values(
            in: "Email dev@example.com at https://example.com token=abcdefghijk"
        )

        #expect(values.contains(.email("dev@example.com")))
        #expect(values.contains(.url(URL(string: "https://example.com")!)))
        #expect(values.contains(.sensitive))
    }

    private func span(_ text: String, x: Double, y: Double, assetID: AssetID) -> OCRSpan {
        OCRSpan(
            assetID: assetID,
            text: text,
            boundingBox: NormalizedRect(x: x, y: y, width: 0.2, height: 0.08),
            confidence: 0.95,
            revision: 3,
            script: .alphabetic
        )
    }
}
