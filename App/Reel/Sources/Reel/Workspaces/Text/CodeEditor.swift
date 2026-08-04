import AppKit
import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI
import TextEngine

/// TextKit 2 editor surface with native undo, find/replace, and a line-number ruler.
struct CodeEditor: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let language: LanguageID
    let settings: EditorSettings
    let fileName: String
    let isReadOnly: Bool
    let undoManager: UndoManager
    let onSave: () -> Void
    let onLongLineModeChange: (Bool) -> Void
    let onLargePaste: () -> Void
    let onPasteRefused: () -> Void
    let onPasteIntoEmptyBuffer: (String) -> Void
    let onSnippetNotice: (String) -> Void
    let diagnostics: [TeXDiagnostic]
    let scrollToLine: Int?
    let navigation: TextEditorNavigation?
    let onVisibleLineChange: (Int) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeEditorContainerView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.providedUndoManager = undoManager
        textView.onSave = context.coordinator.save
        textView.onLargePaste = context.coordinator.largePaste
        textView.onPasteRefused = context.coordinator.refusePaste
        textView.onPasteIntoEmptyBuffer = onPasteIntoEmptyBuffer
        textView.snippetLanguage = language
        textView.snippetFileName = fileName
        textView.onSnippetNotice = onSnippetNotice
        textView.isEditable = !isReadOnly
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
        textView.textStorage?.delegate = context.coordinator
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
        ruler.diagnostics = diagnostics
        context.coordinator.scrollToRequestedLine()
        context.coordinator.navigateToRequestedLocation()
        return CodeEditorContainerView(scrollView: scrollView)
    }

    func updateNSView(_ container: CodeEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.isEditable = !isReadOnly
        textView.snippetLanguage = language
        textView.snippetFileName = fileName
        textView.onSnippetNotice = onSnippetNotice
        textView.onPasteIntoEmptyBuffer = onPasteIntoEmptyBuffer
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
        context.coordinator.ruler?.diagnostics = diagnostics
        context.coordinator.scrollToRequestedLine()
        context.coordinator.navigateToRequestedLocation()
    }

    static func dismantleNSView(
        _ container: CodeEditorContainerView,
        coordinator: Coordinator
    ) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
        var parent: CodeEditor
        fileprivate weak var textView: CodeTextView?
        fileprivate weak var ruler: LineNumberRulerView?
        var isApplyingText = false
        private var scrollObserver: NSObjectProtocol?
        private var lineIndex = TextLineIndex()
        private var lineIndexRevision = 0
        private var lineIndexTask: Task<Void, Never>?
        private var suppressesSoftWrap = false
        private let syntaxHighlighter = SyntaxHighlighter()
        private var syntaxTask: Task<Void, Never>?
        private var syntaxRevision = 0
        private var pendingSyntaxEdit: SyntaxEdit?
        private var isApplyingSyntax = false
        private var syntaxLanguage: LanguageID?
        private var syntaxBaseFont: NSFont?
        private var syntaxEmphasisFont: NSFont?
        private var syntaxBaseColor: NSColor?
        private var syntaxColors: [SyntaxTokenKind: NSColor] = [:]
        private var lastRequestedScrollLine: Int?
        private var lastNavigationID: UUID?
        private var lastReportedVisibleLine: Int?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText, let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            parent.text = value
            rebuildLineIndex(for: value)
            let edit = pendingSyntaxEdit
            pendingSyntaxEdit = nil
            scheduleHighlight(for: value, edit: edit)
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
            pendingSyntaxEdit = nil
            scheduleHighlight(for: value)
            ruler?.needsDisplay = true
            reportSelection(textView.selectedRange())
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isApplyingText, !isApplyingSyntax else {
                return
            }
            pendingSyntaxEdit = SyntaxEdit(
                previousRange: NSRange(
                    location: editedRange.location,
                    length: max(editedRange.length - delta, 0)
                ),
                currentRange: editedRange
            )
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
            let emphasisFont = NSFont.monospacedSystemFont(
                ofSize: settings.fontSize,
                weight: .medium
            )
            let colors: [SyntaxTokenKind: NSColor] = [
                .keyword: NSColor(theme.palette.accent),
                .string: NSColor(theme.palette.success),
                .comment: NSColor(theme.palette.textTertiary),
                .number: NSColor(theme.palette.click),
                .type: NSColor(theme.palette.textPrimary),
                .function: NSColor(theme.palette.textPrimary),
                .property: NSColor(theme.palette.textSecondary),
                .tag: NSColor(theme.palette.textPrimary),
                .heading: NSColor(theme.palette.textPrimary),
                .emphasis: NSColor(theme.palette.textSecondary),
                .link: NSColor(theme.palette.textSecondary),
                .escape: NSColor(theme.palette.click),
                .operator: NSColor(theme.palette.textTertiary),
            ]
            let syntaxAppearanceChanged =
                syntaxLanguage != language
                || syntaxBaseFont != font
                || syntaxBaseColor != foreground
                || syntaxColors != colors
            syntaxLanguage = language
            syntaxBaseFont = font
            syntaxEmphasisFont = emphasisFont
            syntaxBaseColor = foreground
            syntaxColors = colors
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
            let softWrap = settings.softWrap && !suppressesSoftWrap
            textView.isHorizontallyResizable = !softWrap
            textView.textContainer?.widthTracksTextView = softWrap
            textView.textContainer?.containerSize = NSSize(
                width: softWrap
                    ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.hasHorizontalScroller = !softWrap
            scrollView.backgroundColor = background
            ruler?.update(
                background: NSColor(theme.palette.surfacePanel),
                foreground: NSColor(theme.palette.textTertiary),
                separator: NSColor(theme.palette.line),
                fontSize: theme.type.numeric.size
            )
            if syntaxAppearanceChanged {
                scheduleHighlight(for: textView.string)
            }
        }

        func observeScrolling(in scrollView: NSScrollView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ruler?.needsDisplay = true
                    if let textView = self.textView {
                        self.scheduleHighlight(for: textView.string, debounce: true)
                        self.reportVisibleLine(in: textView)
                    }
                }
            }
        }

        func stopObserving() {
            lineIndexTask?.cancel()
            lineIndexTask = nil
            syntaxTask?.cancel()
            syntaxTask = nil
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = nil
        }

        func save(_ currentText: String) {
            parent.text = currentText
            parent.onSave()
        }

        func largePaste() { parent.onLargePaste() }

        func refusePaste() { parent.onPasteRefused() }

        func scrollToRequestedLine() {
            guard let requested = parent.scrollToLine, requested > 0,
                requested != lastRequestedScrollLine,
                let textView
            else { return }
            lastRequestedScrollLine = requested
            let range = lineIndex.range(ofLine: requested)
            textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        }

        func navigateToRequestedLocation() {
            guard let navigation = parent.navigation,
                navigation.id != lastNavigationID,
                let textView
            else { return }
            lastNavigationID = navigation.id
            let lineRange = lineIndex.range(ofLine: navigation.line)
            let location = min(
                lineRange.location + max(navigation.column - 1, 0),
                NSMaxRange(lineRange)
            )
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            textView.window?.makeFirstResponder(textView)
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
                let shouldSuppressSoftWrap = index.longestLineLength > 10_000
                if suppressesSoftWrap != shouldSuppressSoftWrap {
                    suppressesSoftWrap = shouldSuppressSoftWrap
                    parent.onLongLineModeChange(shouldSuppressSoftWrap)
                    if let textView, let scrollView = textView.enclosingScrollView {
                        updateAppearance(
                            textView: textView,
                            scrollView: scrollView,
                            theme: parent.theme,
                            language: parent.language,
                            settings: parent.settings
                        )
                    }
                }
                ruler?.needsDisplay = true
                if let textView {
                    reportSelection(textView.selectedRange())
                    reportVisibleLine(in: textView)
                }
            }
        }

        private func reportSelection(_ selection: NSRange) {
            let position = lineIndex.position(at: selection.location)
            parent.onSelectionChange(selection)
            parent.onCursorChange(position.line, position.column)
        }

        private func reportVisibleLine(in textView: NSTextView) {
            let visible = visibleCharacterRange(in: textView)
            let line = lineIndex.lineNumber(at: visible.location)
            guard line != lastReportedVisibleLine else { return }
            lastReportedVisibleLine = line
            parent.onVisibleLineChange(line)
        }

        private func scheduleHighlight(
            for source: String,
            edit: SyntaxEdit? = nil,
            debounce: Bool = false
        ) {
            guard let textView else { return }
            syntaxRevision += 1
            let revision = syntaxRevision
            let language = parent.language
            let visibleRange = visibleCharacterRange(in: textView)
            syntaxTask?.cancel()
            syntaxTask = Task { [weak self] in
                if debounce {
                    do {
                        try await Task.sleep(for: .milliseconds(40))
                    } catch {
                        return
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let result = await syntaxHighlighter.highlights(
                    in: source,
                    language: language,
                    visibleRange: visibleRange,
                    edit: edit
                )
                guard !Task.isCancelled, revision == syntaxRevision,
                    textView.string == source
                else { return }
                applySyntax(result, to: textView)
            }
        }

        private func visibleCharacterRange(in textView: NSTextView) -> NSRange {
            let sourceLength = (textView.string as NSString).length
            guard sourceLength > 0 else { return NSRange(location: 0, length: 0) }
            let visible = textView.visibleRect
            let start = min(
                textView.characterIndexForInsertion(at: visible.origin),
                sourceLength
            )
            let endPoint = NSPoint(x: visible.maxX, y: visible.maxY)
            let end = min(
                max(textView.characterIndexForInsertion(at: endPoint) + 1, start),
                sourceLength
            )
            return NSRange(location: start, length: end - start)
        }

        private func applySyntax(
            _ result: SyntaxHighlightResult,
            to textView: NSTextView
        ) {
            guard let storage = textView.textStorage, let syntaxBaseFont,
                let syntaxBaseColor
            else { return }
            let fullLength = storage.length
            let styledRange = NSIntersectionRange(
                result.styledRange,
                NSRange(location: 0, length: fullLength)
            )
            guard styledRange.length > 0 else { return }
            isApplyingSyntax = true
            storage.beginEditing()
            storage.addAttributes(
                [.font: syntaxBaseFont, .foregroundColor: syntaxBaseColor],
                range: styledRange
            )
            for token in result.tokens {
                let range = NSIntersectionRange(token.range, styledRange)
                guard range.length > 0, let color = syntaxColors[token.kind] else { continue }
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if tokenUsesEmphasisFont(token.kind), let syntaxEmphasisFont {
                    attributes[.font] = syntaxEmphasisFont
                }
                storage.addAttributes(attributes, range: range)
            }
            storage.endEditing()
            isApplyingSyntax = false
        }

        private func tokenUsesEmphasisFont(_ kind: SyntaxTokenKind) -> Bool {
            switch kind {
            case .keyword, .type, .function, .tag, .heading: true
            default: false
            }
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

struct TextEditorNavigation: Equatable {
    let id = UUID()
    var line: Int
    var column: Int

    init(line: Int, column: Int = 1) {
        self.line = line
        self.column = column
    }
}
