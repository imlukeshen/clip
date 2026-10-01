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

    /// Every Mermaid block in `markdown`, in document order.
    public static func diagrams(in markdown: String) -> [MermaidDiagram] {
        guard let expression else { return [] }
        let text = markdown as NSString
        return expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: text.length)
        ).map { match in
            MermaidDiagram(
                range: match.range,
                closingFenceRange: match.range(at: 2),
                source: text.substring(with: match.range(at: 1))
            )
        }
    }

    private static let expression = try? NSRegularExpression(
        pattern: #"(?ms)^```[ \t]*mermaid[ \t]*\n(.*?)\n?(^```)[ \t]*$"#,
        options: [.caseInsensitive]
    )
}
