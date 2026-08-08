import AppKit
import TextEngine

/// Line-number gutter drawn beside the source view.
///
/// This is a plain sibling view rather than an `NSRulerView`. A scroll view
/// with a visible ruler reserves the ruler by offsetting its clip view's
/// bounds, and inside the layer-backed hierarchy SwiftUI hosts the editor in,
/// the document view then stops reaching the screen: the gutter and the
/// background still paint, but no glyph, caret wash, or bracket rect ever
/// composites. Owning the gutter keeps line numbers and TeX diagnostics while
/// leaving the scroll view in its ordinary, unreserved configuration.
@MainActor
final class LineNumberGutterView: NSView {
    static let thickness: CGFloat = 48

    private weak var textView: NSTextView?
    private var numberColor = NSColor.secondaryLabelColor
    private var separatorColor = NSColor.separatorColor
    private var gutterBackground = NSColor.windowBackgroundColor
    private var currentLineColor = NSColor.clear
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    var lineIndex = TextLineIndex()
    var diagnostics: [TeXDiagnostic] = [] {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.thickness, height: 0))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool {
        gutterBackground.alphaComponent >= 1
    }

    func update(
        background: NSColor,
        foreground: NSColor,
        separator: NSColor,
        currentLine: NSColor,
        fontSize: CGFloat
    ) {
        gutterBackground = background
        numberColor = foreground
        separatorColor = separator
        currentLineColor = currentLine
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        gutterBackground.setFill()
        dirtyRect.fill()
        guard let textView, textView.window != nil else {
            separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
            return
        }
        // Carry the active row across the gutter so it reads as one band
        // rather than stopping at the separator.
        if let lineRect = (textView as? CodeTextView)?.currentLineRect {
            let row = convert(lineRect, from: textView)
            currentLineColor.setFill()
            NSRect(x: 0, y: row.minY, width: bounds.width, height: row.height)
                .intersection(dirtyRect)
                .fill()
        }
        separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        let source = textView.string as NSString
        let visible = textView.visibleRect
        let startIndex = min(
            textView.characterIndexForInsertion(at: NSPoint(x: 0, y: visible.minY)),
            source.length
        )
        var lineNumber = lineIndex.lineNumber(at: startIndex)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        let diagnosticLines = Dictionary(
            grouping: diagnostics.compactMap { diagnostic in
                diagnostic.line.map { ($0, diagnostic.severity) }
            }, by: \.0)
        while lineNumber <= lineIndex.lineCount {
            let indexedRange = lineIndex.range(ofLine: lineNumber)
            let location = min(indexedRange.location, source.length)
            let range = NSRange(
                location: location,
                length: location < source.length ? 1 : 0
            )
            guard let lineRect = localRect(for: range, in: textView) else { break }
            if lineRect.minY > visible.maxY { break }
            if lineRect.maxY >= visible.minY {
                let gutterPoint = convert(
                    NSPoint(x: textView.bounds.minX, y: lineRect.minY),
                    from: textView
                )
                if let severity = diagnosticLines[lineNumber]?.map(\.1).sorted(by: {
                    $0.sortOrder < $1.sortOrder
                }).first {
                    severity.markerColor.setFill()
                    NSBezierPath(
                        ovalIn: NSRect(
                            x: 7,
                            y: gutterPoint.y + max((lineRect.height - 7) / 2, 0),
                            width: 7,
                            height: 7
                        )
                    ).fill()
                }
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: bounds.width - size.width - 9,
                        y: gutterPoint.y + max((lineRect.height - size.height) / 2, 0)
                    ),
                    withAttributes: attributes
                )
            }
            lineNumber += 1
        }
    }

    private func localRect(for range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let window = textView.window else { return nil }
        var actual = NSRange()
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actual)
        return textView.convert(window.convertFromScreen(screenRect), from: nil)
    }
}

extension TeXDiagnosticSeverity {
    fileprivate var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .information: 2
        }
    }

    fileprivate var markerColor: NSColor {
        switch self {
        case .error: .systemRed
        case .warning: .systemOrange
        case .information: .systemBlue
        }
    }
}
