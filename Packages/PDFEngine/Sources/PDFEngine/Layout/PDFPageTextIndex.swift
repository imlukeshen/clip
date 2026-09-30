import CoreModel
import Foundation

/// The complete editable structure of one page: paragraphs, lines and spans.
///
/// Built once from a finished page analysis, before any editing is offered, so
/// a click resolves against the whole page rather than whichever text object
/// happened to be under the pointer.
public struct PDFPageTextIndex: Sendable, Equatable {
    public var paragraphs: [PDFTextParagraph]

    public init(paragraphs: [PDFTextParagraph]) {
        self.paragraphs = paragraphs
    }

    public static let empty = PDFPageTextIndex(paragraphs: [])

    public var isEmpty: Bool { paragraphs.isEmpty }

    /// The smallest paragraph under a normalized page point.
    public func paragraph(containing point: CGPoint) -> PDFTextParagraph? {
        paragraphs
            .filter { $0.contains(point) }
            .min { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    public func paragraph(containingObject objectIndex: Int) -> PDFTextParagraph? {
        paragraphs.first { $0.pageObjectIndexes.contains(objectIndex) }
    }

    /// Assembles glyphs into spans, lines and paragraphs.
    public static func build(from analysis: PDFPageAnalysis) -> PDFPageTextIndex {
        let spans = makeSpans(from: analysis)
        guard !spans.isEmpty else { return .empty }
        return PDFPageTextIndex(paragraphs: makeParagraphs(from: makeLines(from: spans)))
    }

    // MARK: - Spans

    /// Runs of glyphs sharing one object, face and size.
    private static func makeSpans(from analysis: PDFPageAnalysis) -> [PDFTextSpan] {
        var colors: [Int: RGBA] = [:]
        var sizes: [Int: Double] = [:]
        for block in analysis.textBlocks {
            colors[block.pageObjectIndex] = block.color
            sizes[block.pageObjectIndex] = block.renderedFontSize
        }

        var spans: [PDFTextSpan] = []
        var text = ""
        var bounds: CGRect?
        var objectIndex: Int?
        var font: PDFFontDescriptor?

        func flush() {
            guard let objectIndex, let bounds, !text.isEmpty else { return }
            spans.append(
                PDFTextSpan(
                    pageObjectIndex: objectIndex,
                    text: text,
                    bounds: bounds,
                    font: font ?? PDFFontDescriptor(postScriptName: "Helvetica"),
                    fontSize: sizes[objectIndex] ?? 12,
                    color: colors[objectIndex] ?? .black
                )
            )
            text = ""
        }

        for glyph in analysis.glyphs {
            guard let owner = glyph.pageObjectIndex, let glyphBounds = glyph.bounds else {
                continue
            }
            let breaksRun =
                owner != objectIndex
                || glyph.font != font
                || !(bounds.map { sharesLine($0, glyphBounds) } ?? true)
            if breaksRun {
                flush()
                bounds = nil
                objectIndex = owner
                font = glyph.font
            }
            text.append(glyph.text)
            bounds = bounds.map { $0.union(glyphBounds) } ?? glyphBounds
        }
        flush()
        return spans
    }

    // MARK: - Lines

    /// Spans sitting on one baseline, left to right.
    private static func makeLines(from spans: [PDFTextSpan]) -> [PDFTextLine] {
        var lines: [[PDFTextSpan]] = []
        for span in spans {
            let index = lines.firstIndex { row in
                row.contains { sharesLine($0.bounds, span.bounds) }
            }
            if let index {
                lines[index].append(span)
            } else {
                lines.append([span])
            }
        }
        return
            lines
            .map { row -> PDFTextLine in
                let ordered = row.sorted { $0.bounds.minX < $1.bounds.minX }
                let bounds = ordered.dropFirst().reduce(ordered[0].bounds) { $0.union($1.bounds) }
                return PDFTextLine(spans: ordered, bounds: bounds)
            }
            .sorted { $0.bounds.minY < $1.bounds.minY }
    }

    // MARK: - Paragraphs

    /// Consecutive lines separated by no more than ordinary leading and sharing
    /// a horizontal column.
    private static func makeParagraphs(from lines: [PDFTextLine]) -> [PDFTextParagraph] {
        var paragraphs: [PDFTextParagraph] = []
        var current: [PDFTextLine] = []

        func flush() {
            guard let first = current.first else { return }
            let bounds = current.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
            paragraphs.append(PDFTextParagraph(lines: current, bounds: bounds))
            current = []
        }

        for line in lines {
            guard let previous = current.last else {
                current = [line]
                continue
            }
            let gap = line.bounds.minY - previous.bounds.maxY
            // Generous enough for normal leading, tight enough that a heading
            // or the next paragraph starts a new block.
            let leadingLimit = max(previous.bounds.height, line.bounds.height) * 0.9
            let overlapsColumn =
                min(previous.bounds.maxX, line.bounds.maxX)
                > max(previous.bounds.minX, line.bounds.minX)
            if gap >= 0, gap <= leadingLimit, overlapsColumn {
                current.append(line)
            } else {
                flush()
                current = [line]
            }
        }
        flush()
        return paragraphs
    }

    /// Whether two boxes sit on the same visual line.
    private static func sharesLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard overlap > 0 else { return false }
        return overlap >= 0.5 * min(lhs.height, rhs.height)
    }
}
