import CoreModel
import Foundation

/// A run of glyphs drawn with one font, size and colour.
///
/// A PDF content stream starts a new text object at every formatting change, so
/// a single visual paragraph is typically several objects: the roman lead-in,
/// the bold phrase, the roman continuation. A span is that unit — the thing the
/// file actually stores — and is deliberately *not* the unit a person edits.
public struct PDFTextSpan: Sendable, Equatable {
    /// Text object that drew this run, matching ``PDFTextBlock/pageObjectIndex``.
    public var pageObjectIndex: Int
    public var text: String
    /// Normalized page coordinates with an upper-left origin.
    public var bounds: CGRect
    public var font: PDFFontDescriptor
    /// Size as drawn, in PDF points.
    public var fontSize: Double
    public var color: RGBA

    public init(
        pageObjectIndex: Int,
        text: String,
        bounds: CGRect,
        font: PDFFontDescriptor,
        fontSize: Double,
        color: RGBA
    ) {
        self.pageObjectIndex = pageObjectIndex
        self.text = text
        self.bounds = bounds
        self.font = font
        self.fontSize = fontSize
        self.color = color
    }

    /// Whether two runs are alike enough to belong to one span.
    public func matchesFormatting(of other: PDFTextSpan) -> Bool {
        pageObjectIndex == other.pageObjectIndex
            && font == other.font
            && abs(fontSize - other.fontSize) < 0.01
            && color == other.color
    }
}
