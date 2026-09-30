import Foundation

/// Spans sharing a baseline, ordered left to right.
public struct PDFTextLine: Sendable, Equatable {
    public var spans: [PDFTextSpan]
    /// Normalized page coordinates with an upper-left origin.
    public var bounds: CGRect

    public init(spans: [PDFTextSpan], bounds: CGRect) {
        self.spans = spans
        self.bounds = bounds
    }

    public var text: String { spans.map(\.text).joined() }

    /// Object indexes that contributed to this line, in visual order.
    public var pageObjectIndexes: [Int] {
        var seen: Set<Int> = []
        return spans.compactMap { seen.insert($0.pageObjectIndex).inserted ? $0.pageObjectIndex : nil }
    }
}
