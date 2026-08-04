import AppKit
import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI

/// TextKit 2 editor surface with native undo, find/replace, and a line-number ruler.
struct CodeEditor: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let language: LanguageID
    let settings: EditorSettings
    let undoManager: UndoManager
    let onSave: () -> Void
    let onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeEditorContainerView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.providedUndoManager = undoManager
        textView.onSave = context.coordinator.save
        textView.isEditable = true
        textView.isSelectable = true
        textView.setAccessibilityIdentifier("text-editor")
        textView.isRichText = false
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(
            width: theme.metrics.spacing.lg,
            height: theme.metrics.spacing.md
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true

        let scrollView = NSScrollView()
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.observeScrolling(in: scrollView)
        context.coordinator.apply(text, to: textView)
        context.coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            language: language,
            settings: settings
        )
        return CodeEditorContainerView(scrollView: scrollView)
    }

    func updateNSView(_ container: CodeEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        if !context.coordinator.isApplyingText, textView.string != text {
            context.coordinator.apply(text, to: textView)
        }
        context.coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            language: language,
            settings: settings
        )
    }

    static func dismantleNSView(
        _ container: CodeEditorContainerView,
        coordinator: Coordinator
    ) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        fileprivate weak var textView: CodeTextView?
        fileprivate weak var ruler: LineNumberRulerView?
        var isApplyingText = false
        private var scrollObserver: NSObjectProtocol?
        private var lineIndex = TextLineIndex()
        private var lineIndexRevision = 0
        private var lineIndexTask: Task<Void, Never>?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText, let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            parent.text = value
            rebuildLineIndex(for: value)
            ruler?.needsDisplay = true
            reportSelection(textView.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportSelection(textView.selectedRange())
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }

        fileprivate func apply(_ value: String, to textView: CodeTextView) {
            let selection = textView.selectedRange()
            isApplyingText = true
            let manager = textView.undoManager
            manager?.disableUndoRegistration()
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let replacement = NSAttributedString(string: value)
            _ = textView.performValidatedReplacement(in: fullRange, with: replacement)
            manager?.enableUndoRegistration()
            textView.setSelectedRange(
                NSRange(location: min(selection.location, (value as NSString).length), length: 0)
            )
            isApplyingText = false
            rebuildLineIndex(for: value)
            ruler?.needsDisplay = true
        }

        fileprivate func updateAppearance(
            textView: CodeTextView,
            scrollView: NSScrollView,
            theme: Theme,
            language: LanguageID,
            settings: EditorSettings
        ) {
            let font = NSFont.monospacedSystemFont(
                ofSize: settings.fontSize,
                weight: .regular
            )
            let foreground = NSColor(theme.palette.textPrimary)
            let background = NSColor(theme.palette.surfaceBase)
            textView.font = font
            textView.textColor = foreground
            textView.insertionPointColor = foreground
            textView.backgroundColor = background
            textView.currentLineColor = NSColor(theme.palette.accentDim)
            let commentDelimiters = commentDelimiters(for: language)
            textView.commentPrefix = commentDelimiters.prefix
            textView.commentSuffix = commentDelimiters.suffix
            textView.tabWidth = settings.tabWidth
            textView.showsInvisibleMarkers = settings.showInvisibles
            textView.invisibleMarkerColor = NSColor(theme.palette.textTertiary)
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: foreground,
            ]
            textView.isHorizontallyResizable = !settings.softWrap
            textView.textContainer?.widthTracksTextView = settings.softWrap
            textView.textContainer?.containerSize = NSSize(
                width: settings.softWrap
                    ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = !settings.softWrap
            scrollView.backgroundColor = background
            ruler?.update(
                background: NSColor(theme.palette.surfacePanel),
                foreground: NSColor(theme.palette.textTertiary),
                separator: NSColor(theme.palette.line),
                fontSize: theme.type.numeric.size
            )
        }

        func observeScrolling(in scrollView: NSScrollView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        func stopObserving() {
            lineIndexTask?.cancel()
            lineIndexTask = nil
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = nil
        }

        func save(_ currentText: String) {
            parent.text = currentText
            parent.onSave()
        }

        private func rebuildLineIndex(for value: String) {
            lineIndexRevision += 1
            let revision = lineIndexRevision
            lineIndexTask?.cancel()
            lineIndexTask = Task { [weak self] in
                let index = await Task.detached(priority: .userInitiated) {
                    TextLineIndex.make(for: value)
                }.value
                guard !Task.isCancelled, let self, revision == lineIndexRevision,
                    let index
                else { return }
                lineIndex = index
                textView?.lineIndex = index
                ruler?.lineIndex = index
                ruler?.needsDisplay = true
                if let textView {
                    reportSelection(textView.selectedRange())
                }
            }
        }

        private func reportSelection(_ selection: NSRange) {
            let position = lineIndex.position(at: selection.location)
            parent.onCursorChange(position.line, position.column)
        }

        private func commentDelimiters(for language: LanguageID) -> (prefix: String, suffix: String)
        {
            switch language {
            case .python, .bash, .yaml: ("#", "")
            case .latex: ("%", "")
            case .sql: ("--", "")
            case .html, .xml: ("<!--", "-->")
            default: ("//", "")
            }
        }
    }
}
