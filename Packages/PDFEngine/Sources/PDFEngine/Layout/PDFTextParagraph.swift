import Foundation

/// Lines that read as one block of prose, and the unit a person edits.
///
/// A PDF stores no paragraphs — only text objects split at every formatting
/// change and re-positioned per line. Editing those directly is what makes a
/// sentence behave like a row of boxes. Grouping them back into a paragraph
/// restores the thing the author wrote, while every span inside it keeps the
/// object index and coordinates needed to write the edit back to the page.
public struct PDFTextParagraph: Sendable, Equatable, Identifiable {
    /// Lowest source object index in the paragraph; stable for a given page.
    public let id: Int
    public var lines: [PDFTextLine]
    /// Normalized page coordinates with an upper-left origin.
    public var bounds: CGRect

    public init(lines: [PDFTextLine], bounds: CGRect) {
        self.lines = lines
        self.bounds = bounds
        self.id =
            lines.flatMap(\.spans).map(\.pageObjectIndex).min() ?? 0
    }

    /// Every span in reading order.
    public var spans: [PDFTextSpan] { lines.flatMap(\.spans) }

    /// Where one span sits inside ``text``.
    public struct SpanPlacement: Sendable, Equatable {
        public var span: PDFTextSpan
        public var start: Int
        public var length: Int

        public var end: Int { start + length }

        public init(span: PDFTextSpan, start: Int, length: Int) {
            self.span = span
            self.start = start
            self.length = length
        }
    }

    /// Where one line sits inside ``text``.
    public struct LinePlacement: Sendable, Equatable {
        public var line: PDFTextLine
        public var start: Int
        public var length: Int

        public var end: Int { start + length }

        public init(line: PDFTextLine, start: Int, length: Int) {
            self.line = line
            self.start = start
            self.length = length
        }
    }

    /// The paragraph as one string, keeping the page's own line breaks.
    ///
    /// The breaks are preserved rather than replaced with spaces so an editor
    /// can lay the text out exactly where the page had it. Re-joining into one
    /// flow would let the editor pick its own wrap points, and every line after
    /// the first would visibly jump the moment editing opened.
    public var text: String { assembled().text }

    /// Each line with the range it occupies in ``text``.
    public var linePlacements: [LinePlacement] { assembled().lines }

    /// Each span with the range it occupies in ``text``.
    ///
    /// Derived from the same walk as `text`, so an offset in the edited string
    /// can always be attributed to the span — and therefore the PDF object —
    /// it came from. The synthetic join space belongs to no span, which is
    /// correct: nothing in the file corresponds to it.
    public var spanPlacements: [SpanPlacement] { assembled().placements }

    private func assembled() -> (
        text: String,
        placements: [SpanPlacement],
        lines: [LinePlacement]
    ) {
        var text = ""
        var placements: [SpanPlacement] = []
        var linePlacements: [LinePlacement] = []
        for line in lines {
            if !text.isEmpty { text.append("\n") }
            let lineStart = text.count
            for span in line.spans {
                let start = text.count
                text.append(span.text)
                placements.append(
                    SpanPlacement(span: span, start: start, length: span.text.count)
                )
            }
            linePlacements.append(
                LinePlacement(line: line, start: lineStart, length: text.count - lineStart)
            )
        }
        return (text, placements, linePlacements)
    }

    /// Source objects this paragraph was assembled from, lowest first.
    public var pageObjectIndexes: [Int] {
        Array(Set(spans.map(\.pageObjectIndex))).sorted()
    }

    /// Whether a normalized page point falls inside the paragraph.
    public func contains(_ point: CGPoint) -> Bool {
        bounds.insetBy(dx: -0.004, dy: -0.004).contains(point)
    }
}
