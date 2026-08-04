import AppKit

@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var numberColor = NSColor.secondaryLabelColor
    private var separatorColor = NSColor.separatorColor
    private var rulerBackground = NSColor.windowBackgroundColor
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    var lineIndex = TextLineIndex()

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(
        background: NSColor,
        foreground: NSColor,
        separator: NSColor,
        fontSize: CGFloat
    ) {
        rulerBackground = background
        numberColor = foreground
        separatorColor = separator
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        rulerBackground.setFill()
        rect.fill()
        separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let textView, textView.window != nil else { return }

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
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                let rulerPoint = convert(
                    NSPoint(x: textView.bounds.minX, y: lineRect.minY),
                    from: textView
                )
                label.draw(
                    at: NSPoint(
                        x: bounds.width - size.width - 9,
                        y: rulerPoint.y + max((lineRect.height - size.height) / 2, 0)
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
