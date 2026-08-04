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
        // NSTextView's mature layout-manager path remains the most reliable
        // editable surface on macOS 14. The TextKit 2 convenience initializer
        // can accept input while failing to paint newly inserted glyphs after
        // SwiftUI reparents the view inside a split view. That looks exactly
        // like typing is disabled even though the buffer and caret advance.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: .zero, textContainer: textContainer)
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
        textView.textContainer?.lineFragmentPadding = 0
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
        context.coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            language: language,
            settings: settings
        )
        context.coordinator.apply(text, to: textView)
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
        private let markdownFencedCodeHighlighter = MarkdownFencedCodeHighlighter()
        private var syntaxTask: Task<Void, Never>?
        private var syntaxRevision = 0
        private var pendingSyntaxEdit: SyntaxEdit?
        private var isApplyingSyntax = false
        private var syntaxLanguage: LanguageID?
        private var syntaxBaseFont: NSFont?
        private var syntaxEmphasisFont: NSFont?
        private var markdownCodeEmphasisFont: NSFont?
        private var syntaxBaseColor: NSColor?
        private var syntaxParagraphStyle: NSParagraphStyle?
        private var syntaxColors: [SyntaxTokenKind: NSColor] = [:]
        private var markdownMarkerColor: NSColor?
        private var markdownCodeBackground: NSColor?
        private var markdownQuoteColor: NSColor?
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
            applyVisibleBaseStyle(in: edit?.currentRange, to: textView)
            // Markdown presentation includes line-level hierarchy outside the exact edit.
            // Repaint the visible writing canvas after a formatting command so headings
            // and inline styles cannot be flattened by NSTextView's attributed replacement.
            scheduleHighlight(for: value, edit: parent.language == .markdown ? nil : edit)
            if parent.language == .markdown {
                refreshMarkdownPresentation(in: textView)
            }
            ruler?.needsDisplay = true
            reportSelection(textView.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportSelection(textView.selectedRange())
            if parent.language == .markdown {
                refreshMarkdownPresentation(in: textView)
            }
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }

        fileprivate func apply(_ value: String, to textView: CodeTextView) {
            let selection = textView.selectedRange()
            isApplyingText = true
            let manager = textView.undoManager
            manager?.disableUndoRegistration()
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            // Carry the editor's explicit foreground and font into programmatic
            // updates. An unstyled attributed replacement defaults to black,
            // which is effectively invisible in Clip's dark editor.
            let replacement = NSAttributedString(
                string: value,
                attributes: textView.typingAttributes
            )
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
            let usesProseLayout = language == .plainText || language == .markdown
            let font =
                usesProseLayout
                ? NSFont.systemFont(ofSize: settings.fontSize, weight: .regular)
                : NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
            let foreground = NSColor(theme.palette.textPrimary)
            let background = NSColor(theme.palette.surfaceBase)
            let markerColor = NSColor(theme.palette.textTertiary).withAlphaComponent(0.72)
            let codeBackground = NSColor(theme.palette.surfaceRaised)
            let quoteColor = NSColor(theme.palette.accent)
            let emphasisFont =
                usesProseLayout
                ? NSFont.systemFont(ofSize: settings.fontSize, weight: .semibold)
                : NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .medium)
            let codeEmphasisFont = NSFont.monospacedSystemFont(
                ofSize: max(settings.fontSize - 1, 10),
                weight: .medium
            )
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = usesProseLayout ? 3 : 1
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
                || markdownCodeEmphasisFont != codeEmphasisFont
                || syntaxBaseColor != foreground
                || syntaxColors != colors
                || markdownMarkerColor != markerColor
                || markdownCodeBackground != codeBackground
                || markdownQuoteColor != quoteColor
            syntaxLanguage = language
            syntaxBaseFont = font
            syntaxEmphasisFont = emphasisFont
            markdownCodeEmphasisFont = codeEmphasisFont
            syntaxBaseColor = foreground
            syntaxParagraphStyle = paragraphStyle
            syntaxColors = colors
            markdownMarkerColor = markerColor
            markdownCodeBackground = codeBackground
            markdownQuoteColor = quoteColor
            textView.font = font
            textView.textColor = foreground
            textView.insertionPointColor = foreground
            textView.backgroundColor = background
            textView.currentLineColor =
                usesProseLayout ? background : NSColor(theme.palette.accentDim)
            textView.textContainerInset = NSSize(
                width: usesProseLayout ? theme.metrics.spacing.xxl : theme.metrics.spacing.lg,
                height: usesProseLayout ? theme.metrics.spacing.xl : theme.metrics.spacing.md
            )
            let commentDelimiters = commentDelimiters(for: language)
            textView.commentPrefix = commentDelimiters.prefix
            textView.commentSuffix = commentDelimiters.suffix
            textView.tabWidth = settings.tabWidth
            textView.showsInvisibleMarkers = settings.showInvisibles
            textView.invisibleMarkerColor = NSColor(theme.palette.textTertiary)
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraphStyle,
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
            scrollView.rulersVisible = !usesProseLayout
            ruler?.update(
                background: NSColor(theme.palette.surfacePanel),
                foreground: NSColor(theme.palette.textTertiary),
                separator: NSColor(theme.palette.line),
                fontSize: theme.type.numeric.size
            )
            if syntaxAppearanceChanged {
                applyVisibleBaseStyle(in: nil, to: textView)
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
                let fencedCodeTokens =
                    language == .markdown
                    ? await markdownFencedCodeHighlighter.highlights(
                        in: source,
                        visibleRange: visibleRange
                    ) : []
                guard !Task.isCancelled, revision == syntaxRevision,
                    textView.string == source
                else { return }
                applySyntax(result, fencedCodeTokens: fencedCodeTokens, to: textView)
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
            fencedCodeTokens: [SyntaxToken],
            to textView: NSTextView
        ) {
            guard let storage = textView.textStorage, let syntaxBaseFont,
                let syntaxBaseColor
            else { return }
            let fullLength = storage.length
            let requestedRange = NSIntersectionRange(
                result.styledRange,
                NSRange(location: 0, length: fullLength)
            )
            let styledRange: NSRange
            if parent.language == .markdown, requestedRange.length > 0 {
                styledRange = (textView.string as NSString).lineRange(for: requestedRange)
            } else {
                styledRange = requestedRange
            }
            guard styledRange.length > 0 else { return }
            isApplyingSyntax = true
            storage.beginEditing()
            var baseAttributes: [NSAttributedString.Key: Any] = [
                .font: syntaxBaseFont,
                .foregroundColor: syntaxBaseColor,
            ]
            if let syntaxParagraphStyle {
                baseAttributes[.paragraphStyle] = syntaxParagraphStyle
            }
            storage.removeAttribute(.backgroundColor, range: styledRange)
            storage.removeAttribute(.strikethroughStyle, range: styledRange)
            storage.removeAttribute(.underlineStyle, range: styledRange)
            storage.removeAttribute(.underlineColor, range: styledRange)
            storage.addAttributes(baseAttributes, range: styledRange)
            for token in result.tokens {
                let range = NSIntersectionRange(token.range, styledRange)
                guard range.length > 0, let color = syntaxColors[token.kind] else { continue }
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if tokenUsesEmphasisFont(token.kind), let syntaxEmphasisFont {
                    attributes[.font] = syntaxEmphasisFont
                }
                storage.addAttributes(attributes, range: range)
            }
            if parent.language == .markdown {
                applyMarkdownPresentation(
                    source: textView.string,
                    range: styledRange,
                    selectedRange: textView.selectedRange(),
                    storage: storage
                )
                applyTokens(fencedCodeTokens, intersecting: styledRange, to: storage)
            }
            storage.endEditing()
            isApplyingSyntax = false
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsDisplay = true
        }

        private func applyTokens(
            _ tokens: [SyntaxToken],
            intersecting styledRange: NSRange,
            to storage: NSTextStorage
        ) {
            for token in tokens {
                let range = NSIntersectionRange(token.range, styledRange)
                guard range.length > 0, let color = syntaxColors[token.kind] else { continue }
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if tokenUsesEmphasisFont(token.kind), let markdownCodeEmphasisFont {
                    attributes[.font] = markdownCodeEmphasisFont
                }
                storage.addAttributes(attributes, range: range)
            }
        }

        /// NSTextView may reset typing attributes while SwiftUI reparents the
        /// split view. Paint inserted characters with Clip's explicit base
        /// style synchronously; syntax colors can then layer on asynchronously.
        private func applyVisibleBaseStyle(
            in requestedRange: NSRange?,
            to textView: NSTextView
        ) {
            guard let storage = textView.textStorage, let syntaxBaseFont,
                let syntaxBaseColor, storage.length > 0
            else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let range = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
            guard range.length > 0 else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: syntaxBaseFont,
                .foregroundColor: syntaxBaseColor,
            ]
            if let syntaxParagraphStyle {
                attributes[.paragraphStyle] = syntaxParagraphStyle
            }
            isApplyingSyntax = true
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(.strikethroughStyle, range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.underlineColor, range: range)
            storage.addAttributes(attributes, range: range)
            isApplyingSyntax = false
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsDisplay = true
        }

        /// Presents Markdown as one calm writing canvas while preserving its portable source.
        /// Markers stay faintly visible at the caret, while content carries the visual hierarchy.
        private func applyMarkdownPresentation(
            source: String,
            range: NSRange,
            selectedRange: NSRange,
            storage: NSTextStorage
        ) {
            guard let syntaxBaseFont, let syntaxBaseColor, let markdownMarkerColor,
                let markdownCodeBackground, let markdownQuoteColor
            else { return }
            let nsSource = source as NSString
            let safeRange = NSIntersectionRange(
                range, NSRange(location: 0, length: nsSource.length))
            guard safeRange.length > 0 else { return }
            let syntaxColor: (NSRange) -> NSColor = { range in
                self.markdownSyntaxColor(
                    for: range,
                    source: nsSource,
                    selectedRange: selectedRange,
                    visibleColor: markdownMarkerColor
                )
            }

            applyMarkdownMatches(
                pattern: "(?m)^(#{1,6})[ \\t]+(.+?)[ \\t]*#*[ \\t]*$",
                source: source,
                range: safeRange
            ) { match in
                let marker = match.range(at: 1)
                let content = match.range(at: 2)
                guard marker.location != NSNotFound, content.location != NSNotFound else { return }
                let level = min(max(marker.length, 1), 6)
                let scale: CGFloat = [1.78, 1.5, 1.28, 1.12, 1.04, 1.0][level - 1]
                let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
                let headingFont = NSFont.systemFont(
                    ofSize: max(syntaxBaseFont.pointSize * scale, syntaxBaseFont.pointSize),
                    weight: weight
                )
                let paragraph =
                    (syntaxParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacingBefore = level == 1 ? 18 : 12
                paragraph.paragraphSpacing = level <= 2 ? 8 : 5
                storage.addAttributes(
                    [
                        .font: headingFont, .foregroundColor: syntaxBaseColor,
                        .paragraphStyle: paragraph,
                    ],
                    range: match.range
                )
                storage.addAttributes(
                    self.markdownSyntaxAttributes(for: syntaxColor(match.range)),
                    range: marker
                )
            }

            applyMarkdownMatches(
                pattern: "(?m)^(\\s*)((?:[-+*]|[0-9]+\\.)[ \\t]+|[-+*][ \\t]+\\[[ xX]\\][ \\t]+)",
                source: source,
                range: safeRange
            ) { match in
                let marker = match.range(at: 2)
                guard marker.location != NSNotFound else { return }
                storage.addAttributes(
                    [
                        .foregroundColor: markdownQuoteColor,
                        .font: NSFont.systemFont(
                            ofSize: syntaxBaseFont.pointSize, weight: .semibold),
                    ],
                    range: marker
                )
            }

            applyMarkdownMatches(
                pattern: "(?m)^(\\s*>[ \\t]?)",
                source: source,
                range: safeRange
            ) { match in
                let marker = match.range(at: 1)
                guard marker.location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: markdownQuoteColor, range: marker)
                let line = nsSource.lineRange(for: marker)
                let paragraph =
                    (syntaxParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.headIndent = 12
                paragraph.firstLineHeadIndent = 0
                paragraph.paragraphSpacing = 3
                storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
            }

            applyMarkdownMatches(
                pattern: "\\*\\*([^\\n*]+)\\*\\*|__([^\\n_]+)__",
                source: source,
                range: safeRange
            ) { match in
                self.styleDelimitedMatch(
                    match,
                    contentGroups: [1, 2],
                    trait: .boldFontMask,
                    markerColor: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)|(?<!_)_([^_\\n]+)_(?!_)",
                source: source,
                range: safeRange
            ) { match in
                self.styleDelimitedMatch(
                    match,
                    contentGroups: [1, 2],
                    trait: .italicFontMask,
                    markerColor: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "~~([^\\n~]+)~~",
                source: source,
                range: safeRange
            ) { match in
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { return }
                storage.addAttribute(
                    .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                self.dimDelimiters(
                    in: match.range,
                    around: content,
                    color: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "(?<!`)`([^`\\n]+)`(?!`)",
                source: source,
                range: safeRange
            ) { match in
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { return }
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(syntaxBaseFont.pointSize - 1, 10), weight: .regular),
                        .backgroundColor: markdownCodeBackground,
                    ],
                    range: content
                )
                self.dimDelimiters(
                    in: match.range,
                    around: content,
                    color: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)",
                source: source,
                range: safeRange
            ) { match in
                let label = match.range(at: 1)
                let destination = match.range(at: 2)
                guard label.location != NSNotFound, destination.location != NSNotFound else {
                    return
                }
                storage.addAttributes(
                    [
                        .foregroundColor: markdownQuoteColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: markdownQuoteColor,
                    ],
                    range: label
                )
                let linkSyntaxColor = syntaxColor(match.range)
                storage.addAttributes(
                    self.markdownSyntaxAttributes(for: linkSyntaxColor),
                    range: destination
                )
                let prefixRange = NSRange(location: match.range.location, length: 1)
                let betweenRange = NSRange(location: NSMaxRange(label), length: 2)
                let suffixRange = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
                for marker in [prefixRange, betweenRange, suffixRange] {
                    storage.addAttributes(
                        self.markdownSyntaxAttributes(for: linkSyntaxColor),
                        range: marker
                    )
                }
            }

            applyMarkdownMatches(
                pattern: "!\\[([^\\]\\n]*)\\]\\(([^)\\n]+)\\)",
                source: source,
                range: safeRange
            ) { match in
                let label = match.range(at: 1)
                guard label.location != NSNotFound else { return }
                storage.addAttributes(
                    [
                        .foregroundColor: markdownQuoteColor,
                        .font: NSFont.systemFont(
                            ofSize: syntaxBaseFont.pointSize, weight: .semibold),
                    ],
                    range: label
                )
                let markerColor = syntaxColor(match.range)
                self.dimDelimiters(
                    in: match.range,
                    around: label,
                    color: markerColor,
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "(?m)^([ \\t]*\\|.*\\|[ \\t]*)$",
                source: source,
                range: safeRange
            ) { match in
                let paragraph =
                    (syntaxParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 2
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(syntaxBaseFont.pointSize - 1, 10), weight: .regular),
                        .backgroundColor: markdownCodeBackground.withAlphaComponent(0.55),
                        .paragraphStyle: paragraph,
                    ],
                    range: match.range
                )
            }

            applyMarkdownMatches(
                pattern:
                    "(?m)^[ \\t]*\\|?[ \\t]*:?-{3,}:?[ \\t]*(?:\\|[ \\t]*:?-{3,}:?[ \\t]*)+\\|?[ \\t]*$",
                source: source,
                range: safeRange
            ) { match in
                storage.addAttribute(
                    .foregroundColor, value: markdownMarkerColor, range: match.range)
            }

            applyMarkdownMatches(
                pattern: "\\[\\^([^\\]\\n]+)\\](?::)?",
                source: source,
                range: safeRange
            ) { match in
                storage.addAttributes(
                    [
                        .foregroundColor: markdownQuoteColor,
                        .font: NSFont.systemFont(
                            ofSize: max(syntaxBaseFont.pointSize - 2, 9), weight: .semibold),
                    ],
                    range: match.range
                )
            }

            applyMarkdownMatches(
                pattern: "(?<!\\$)\\$([^\\n$]+)\\$(?!\\$)",
                source: source,
                range: safeRange
            ) { match in
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { return }
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(syntaxBaseFont.pointSize - 1, 10), weight: .regular),
                        .foregroundColor: markdownQuoteColor,
                    ],
                    range: content
                )
                self.dimDelimiters(
                    in: match.range,
                    around: content,
                    color: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "(?ms)^\\$\\$[ \\t]*\\n(.*?)^\\$\\$[ \\t]*$",
                source: source,
                range: safeRange
            ) { match in
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: syntaxBaseFont.pointSize, weight: .regular),
                        .foregroundColor: markdownQuoteColor,
                        .backgroundColor: markdownCodeBackground,
                    ],
                    range: match.range
                )
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { return }
                self.dimDelimiters(
                    in: match.range,
                    around: content,
                    color: syntaxColor(match.range),
                    storage: storage
                )
            }

            applyMarkdownMatches(
                pattern: "(?ms)^```[^\\n]*\\n.*?^```[ \\t]*$",
                source: source,
                range: safeRange
            ) { match in
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(syntaxBaseFont.pointSize - 1, 10), weight: .regular),
                        .backgroundColor: markdownCodeBackground,
                    ],
                    range: match.range
                )
                let firstLine = nsSource.lineRange(
                    for: NSRange(location: match.range.location, length: 0))
                let finalLocation = max(NSMaxRange(match.range) - 1, match.range.location)
                let lastLine = nsSource.lineRange(for: NSRange(location: finalLocation, length: 0))
                storage.addAttributes(
                    self.markdownSyntaxAttributes(for: syntaxColor(firstLine)),
                    range: firstLine
                )
                storage.addAttributes(
                    self.markdownSyntaxAttributes(for: syntaxColor(lastLine)),
                    range: lastLine
                )
            }

            applyMarkdownMatches(
                pattern: "(?m)^[ \\t]{0,3}(?:---+|___+|\\*\\*\\*+)[ \\t]*$",
                source: source,
                range: safeRange
            ) { match in
                storage.addAttributes(
                    [
                        .foregroundColor: markdownMarkerColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: match.range
                )
            }
        }

        private func refreshMarkdownPresentation(in textView: NSTextView) {
            guard parent.language == .markdown, let storage = textView.textStorage,
                storage.length > 0
            else { return }
            let visible = visibleCharacterRange(in: textView)
            let range = (textView.string as NSString).lineRange(for: visible)
            isApplyingSyntax = true
            storage.beginEditing()
            applyMarkdownPresentation(
                source: textView.string,
                range: range,
                selectedRange: textView.selectedRange(),
                storage: storage
            )
            storage.endEditing()
            isApplyingSyntax = false
            textView.needsDisplay = true
        }

        private func applyMarkdownMatches(
            pattern: String,
            source: String,
            range: NSRange,
            apply: (NSTextCheckingResult) -> Void
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            expression.enumerateMatches(in: source, range: range) { match, _, _ in
                if let match { apply(match) }
            }
        }

        private func styleDelimitedMatch(
            _ match: NSTextCheckingResult,
            contentGroups: [Int],
            trait: NSFontTraitMask,
            markerColor: NSColor,
            storage: NSTextStorage
        ) {
            guard
                let content = contentGroups.map({ match.range(at: $0) }).first(where: {
                    $0.location != NSNotFound
                })
            else { return }
            let currentFont =
                storage.attribute(.font, at: content.location, effectiveRange: nil)
                as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let font = NSFontManager.shared.convert(currentFont, toHaveTrait: trait)
            storage.addAttribute(.font, value: font, range: content)
            dimDelimiters(in: match.range, around: content, color: markerColor, storage: storage)
        }

        private func dimDelimiters(
            in fullRange: NSRange,
            around contentRange: NSRange,
            color: NSColor,
            storage: NSTextStorage
        ) {
            let leading = NSRange(
                location: fullRange.location, length: contentRange.location - fullRange.location)
            let trailing = NSRange(
                location: NSMaxRange(contentRange),
                length: NSMaxRange(fullRange) - NSMaxRange(contentRange))
            if leading.length > 0 {
                storage.addAttributes(markdownSyntaxAttributes(for: color), range: leading)
            }
            if trailing.length > 0 {
                storage.addAttributes(markdownSyntaxAttributes(for: color), range: trailing)
            }
        }

        private func markdownSyntaxAttributes(
            for color: NSColor
        ) -> [NSAttributedString.Key: Any] {
            let font: NSFont
            if color.alphaComponent <= 0.001 {
                font = NSFont.systemFont(ofSize: 1)
            } else {
                font = syntaxBaseFont ?? NSFont.systemFont(ofSize: 13)
            }
            return [.foregroundColor: color, .font: font]
        }

        private func markdownSyntaxColor(
            for range: NSRange,
            source: NSString,
            selectedRange: NSRange,
            visibleColor: NSColor
        ) -> NSColor {
            let caret = min(max(selectedRange.location, 0), source.length)
            let activeLine = source.lineRange(for: NSRange(location: caret, length: 0))
            let elementLine = source.lineRange(
                for: NSRange(location: min(range.location, source.length), length: 0)
            )
            return NSIntersectionRange(activeLine, elementLine).length > 0
                ? visibleColor : .clear
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
