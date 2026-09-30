import AppKit
import ReelAppCore
import SwiftUI
import TextEngine

/// The terminal transcript drawn by one native text view.
///
/// A SwiftUI stack of per-line views stuttered while scrolling long output.
/// One `NSTextView` scrolls like Terminal, selects across lines, and grows by
/// appending only the lines that arrived since the last update. It follows
/// new output only while the reader is already at the bottom, so scrolling up
/// during a run is never yanked back down.
struct CodeTerminalTextView: NSViewRepresentable {
    struct Palette {
        var text: NSColor
        var secondary: NSColor
        var tertiary: NSColor
        var danger: NSColor
    }

    let transcript: CodeTranscript
    /// A final status line such as the exit code, or `nil` while running.
    let footer: (text: String, isError: Bool)?
    let placeholder: String?
    let fontSize: Double
    /// Padding around the text, from the theme's spacing scale.
    let inset: CGFloat
    let palette: Palette
    /// The editor line an error line points at, if any.
    let errorTarget: (String) -> Int?
    let onGoToLine: (Int) -> Void

    private static let lineScheme = "clipx-line"

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PinnedScrollView()
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setAccessibilityIdentifier("code-terminal-text")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
            let storage = textView.textStorage
        else { return }
        let coordinator = context.coordinator
        // A resize re-renders the panel without changing what it shows; skip
        // the text work entirely so dragging stays smooth.
        let signature = Signature(
            lineCount: transcript.lines.count,
            lastID: transcript.lines.last?.id,
            tail: transcript.displayLines.dropFirst(transcript.lines.count).map(\.text),
            footer: footer?.text,
            placeholder: placeholder,
            fontSize: fontSize
        )
        guard signature != coordinator.signature else { return }
        coordinator.signature = signature
        let lines = transcript.lines
        let wasAtBottom = Self.isAtBottom(scrollView)
        let styleChanged = coordinator.fontSize != fontSize
        let canAppend =
            !styleChanged && coordinator.renderedIDs.count <= lines.count
            && zip(coordinator.renderedIDs, lines).allSatisfy { $0 == $1.id }

        storage.beginEditing()
        if canAppend {
            // Drop the old tail (unfinished lines and footer), then append.
            storage.deleteCharacters(
                in: NSRange(
                    location: coordinator.completedLength,
                    length: storage.length - coordinator.completedLength))
        } else {
            storage.setAttributedString(NSAttributedString())
            coordinator.renderedIDs = []
            coordinator.completedLength = 0
        }
        for line in lines.dropFirst(coordinator.renderedIDs.count) {
            storage.append(render(line, isFirst: storage.length == 0))
            coordinator.renderedIDs.append(line.id)
        }
        coordinator.completedLength = storage.length
        for line in transcript.displayLines.dropFirst(lines.count) {
            storage.append(render(line, isFirst: storage.length == 0))
        }
        if let footer {
            storage.append(
                styled(
                    footer.text, color: footer.isError ? palette.danger : palette.tertiary,
                    spacingBefore: 6, isFirst: storage.length == 0))
        } else if storage.length == 0, let placeholder {
            storage.append(
                styled(placeholder, color: palette.tertiary, spacingBefore: 0, isFirst: true))
        }
        storage.endEditing()
        coordinator.fontSize = fontSize

        if wasAtBottom || !canAppend {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func render(_ line: CodeTranscript.Line, isFirst: Bool) -> NSAttributedString {
        switch line.kind {
        case .command:
            let result = NSMutableAttributedString(
                attributedString: styled(
                    "$ ", color: palette.tertiary, spacingBefore: 6, isFirst: isFirst))
            result.append(
                styled(line.text, color: palette.secondary, spacingBefore: 6, isFirst: true))
            return result
        case .output:
            return styled(line.text, color: palette.text, spacingBefore: 0, isFirst: isFirst)
        case .error:
            let result = NSMutableAttributedString(
                attributedString: styled(
                    line.text, color: palette.danger, spacingBefore: 0, isFirst: isFirst))
            if let target = errorTarget(line.text),
                let url = URL(string: "\(Self.lineScheme):\(target)")
            {
                let start = isFirst ? 0 : 1  // Skip the leading newline.
                result.addAttribute(
                    .link, value: url,
                    range: NSRange(location: start, length: result.length - start))
                result.addAttribute(
                    .toolTip, value: "Go to line \(target)",
                    range: NSRange(location: start, length: result.length - start))
            }
            return result
        }
    }

    /// One line, preceded by a newline unless it opens the transcript.
    private func styled(
        _ text: String,
        color: NSColor,
        spacingBefore: CGFloat,
        isFirst: Bool
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = isFirst ? 0 : spacingBefore
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: (isFirst ? "" : "\n") + text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    fileprivate static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= document.bounds.maxY - 24
    }

    /// What the text view currently shows, to recognise updates that change
    /// nothing, such as a resize.
    struct Signature: Equatable {
        var lineCount: Int
        var lastID: Int?
        var tail: [String]
        var footer: String?
        var placeholder: String?
        var fontSize: Double
    }

    /// Keeps the newest output in view while the panel is resized, the way a
    /// terminal window does, instead of anchoring to the top.
    final class PinnedScrollView: NSScrollView {
        override func setFrameSize(_ newSize: NSSize) {
            let wasAtBottom = CodeTerminalTextView.isAtBottom(self)
            super.setFrameSize(newSize)
            guard wasAtBottom, let document = documentView else { return }
            let bottom = max(0, document.frame.height - contentView.bounds.height)
            contentView.scroll(to: NSPoint(x: 0, y: bottom))
            reflectScrolledClipView(contentView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var signature: Signature?
        var parent: CodeTerminalTextView
        var renderedIDs: [Int] = []
        var completedLength = 0
        var fontSize: Double = 0

        init(parent: CodeTerminalTextView) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == CodeTerminalTextView.lineScheme,
                let line = Int(
                    url.absoluteString.dropFirst(CodeTerminalTextView.lineScheme.count + 1))
            else { return false }
            parent.onGoToLine(line)
            return true
        }
    }
}
