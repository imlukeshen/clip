import CoreGraphics
import CoreModel
import Foundation

public struct PDFMarkdownConverter: Sendable {
    private let source: PDFiumDocument

    public init(source: PDFiumDocument) {
        self.source = source
    }

    public func convert(_ document: PDFEditDocument) throws -> String {
        let analyses = try document.pages.map { page in
            try page.sourcePageIndex.map { try source.analyzePage(at: $0) }
                ?? PDFPageAnalysis(text: "", glyphs: [], fonts: [])
        }
        return Self.convert(document, analyses: analyses)
    }

    public static func convert(
        _ document: PDFEditDocument,
        analyses: [PDFPageAnalysis]
    ) -> String {
        document.pages.enumerated().map { index, page in
            let analysis =
                analyses.indices.contains(index)
                ? analyses[index] : PDFPageAnalysis(text: "", glyphs: [], fonts: [])
            let content = markdown(page: page, analysis: analysis)
            return "<!-- Page \(index + 1) -->\n\n\(content)"
        }.joined(separator: "\n\n---\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func markdown(page: PDFPage, analysis: PDFPageAnalysis) -> String {
        let redactions = page.layers.flatMap { layer -> [CGRect] in
            if case .redaction(let value) = layer { return value.regions }
            return []
        }
        var glyphs = analysis.glyphs.filter { glyph in
            guard let bounds = glyph.bounds else { return false }
            return !redactions.contains { $0.intersects(bounds) }
        }
        glyphs.append(
            contentsOf: page.layers.compactMap { layer -> PDFTextGlyph? in
                guard case .text(let text) = layer else { return nil }
                return PDFTextGlyph(
                    text: text.text,
                    bounds: text.frame,
                    font: text.font,
                    fontSize: text.fontSize
                )
            }
        )
        let lines = layoutLines(glyphs)
        if lines.isEmpty {
            let fallback = page.ocrText ?? analysis.text
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodySize = median(lines.map(\.fontSize).filter { $0 > 0 }) ?? 12
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let tableEnd = matchingTableEnd(lines, startingAt: index)
            if let tableEnd {
                output.append(markdownTable(Array(lines[index..<tableEnd])))
                index = tableEnd
                continue
            }
            let text = line.cells.joined(separator: " ").trimmed
            if !text.isEmpty {
                let scale = line.fontSize / max(bodySize, 1)
                if scale >= 1.35 {
                    let level = scale >= 2 ? 1 : (scale >= 1.65 ? 2 : 3)
                    output.append("\(String(repeating: "#", count: level)) \(text)")
                } else {
                    output.append(text)
                }
            }
            index += 1
        }
        return output.joined(separator: "\n\n")
    }

    private static func layoutLines(_ glyphs: [PDFTextGlyph]) -> [LayoutLine] {
        let positioned = glyphs.compactMap { glyph -> PositionedGlyph? in
            guard let bounds = glyph.bounds, !glyph.text.isEmpty else { return nil }
            return PositionedGlyph(glyph: glyph, bounds: bounds)
        }.sorted {
            abs($0.bounds.midY - $1.bounds.midY) < 0.006
                ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY < $1.bounds.midY
        }
        var groups: [[PositionedGlyph]] = []
        for glyph in positioned {
            if let last = groups.indices.last,
                abs(
                    (median(groups[last].map { $0.bounds.midY })
                        ?? glyph.bounds.midY) - glyph.bounds.midY
                )
                    <= max(glyph.bounds.height * 0.65, 0.009)
            {
                groups[last].append(glyph)
            } else {
                groups.append([glyph])
            }
        }
        return groups.map { group in
            let sorted = group.sorted { $0.bounds.minX < $1.bounds.minX }
            let typicalWidth = median(sorted.map { max($0.bounds.width, 0.004) }) ?? 0.01
            var cells: [String] = []
            var current = ""
            var previous: PositionedGlyph?
            for glyph in sorted {
                if let previous {
                    let gap = glyph.bounds.minX - previous.bounds.maxX
                    if gap > typicalWidth * 3.2 {
                        if !current.trimmed.isEmpty { cells.append(current.trimmed) }
                        current = ""
                    } else if gap > typicalWidth * 0.35,
                        !(current.last?.isWhitespace ?? true),
                        !(glyph.glyph.text.first?.isWhitespace ?? true)
                    {
                        current += " "
                    }
                }
                current += glyph.glyph.text
                previous = glyph
            }
            if !current.trimmed.isEmpty { cells.append(current.trimmed) }
            return LayoutLine(
                cells: cells,
                fontSize: median(group.map(\.glyph.fontSize)) ?? 12
            )
        }.filter { !$0.cells.isEmpty }
    }

    private static func matchingTableEnd(_ lines: [LayoutLine], startingAt start: Int) -> Int? {
        let columns = lines[start].cells.count
        guard columns >= 2 else { return nil }
        var end = start
        while end < lines.count, lines[end].cells.count == columns { end += 1 }
        return end - start >= 2 ? end : nil
    }

    private static func markdownTable(_ lines: [LayoutLine]) -> String {
        let rows = lines.map { line in
            "| " + line.cells.map(escapeCell).joined(separator: " | ") + " |"
        }
        let separator = "| " + lines[0].cells.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([rows[0], separator] + Array(rows.dropFirst())).joined(separator: "\n")
    }

    private static func escapeCell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let values = values.sorted()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

private struct PositionedGlyph {
    var glyph: PDFTextGlyph
    var bounds: CGRect
}

private struct LayoutLine {
    var cells: [String]
    var fontSize: Double
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
