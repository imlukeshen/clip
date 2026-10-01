import Foundation

/// A ```` ```mermaid ```` fenced block in a Markdown buffer.
public struct MermaidDiagram: Sendable, Equatable {
    /// The range from the opening fence through the closing fence.
    public let range: NSRange
    /// The range of the closing fence line, where a rendered diagram is shown.
    public let closingFenceRange: NSRange
    /// The diagram definition between the fences.
    public let source: String

    /// Creates a diagram description.
    public init(range: NSRange, closingFenceRange: NSRange, source: String) {
        self.range = range
        self.closingFenceRange = closingFenceRange
        self.source = source
    }

    /// Every closed Mermaid block in `markdown`, in document order. Backtick
    /// and tilde fences of any length count, as they do for the block parser.
    public static func diagrams(in markdown: String) -> [MermaidDiagram] {
        let text = markdown as NSString
        return MarkdownFenceScanner.fences(in: markdown).compactMap { fence in
            guard fence.label == "mermaid", let closing = fence.closingMarkerRange else {
                return nil
            }
            var source = text.substring(with: fence.contentRange)
            // "\r\n" is a single Character, so one removeLast drops a CRLF,
            // LF, or CR terminator alike.
            if let last = source.last, last.isNewline { source.removeLast() }
            return MermaidDiagram(range: fence.range, closingFenceRange: closing, source: source)
        }
    }
}
