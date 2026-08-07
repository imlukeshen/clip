import AppKit
import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI
import TextEngine

struct CodeEditorDocumentIdentity: Equatable, Sendable {
    let documentID: DocumentID
    let fileID: FileID
}

/// TextKit 2 editor surface with native undo, find/replace, and a line-number ruler.
struct CodeEditor: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let language: LanguageID
    let settings: EditorSettings
    let documentIdentity: CodeEditorDocumentIdentity
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
    let onMarkdownDocumentChange: (CodeEditorDocumentIdentity, MarkdownDocumentSnapshot) -> Void
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
        textView.onCompositionCommit = { [weak coordinator = context.coordinator] in
            coordinator?.compositionDidCommit()
        }
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
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        let documentChanged = context.coordinator.documentIdentity != documentIdentity
        if documentChanged, textView.hasMarkedText() {
            // Commit the old file's composition while the coordinator still
            // owns its binding. The new file must never inherit marked text.
            textView.unmarkText()
            context.coordinator.compositionDidCommit()
        }
        context.coordinator.parent = self
        _ = context.coordinator.transition(to: documentIdentity)
        let languageChanged = context.coordinator.presentedLanguage != language
        let shouldRestoreEditing =
            context.coordinator.isTextEditorActive
            || textView.window?.firstResponder === textView
        context.coordinator.presentedLanguage = language
        textView.isEditable = !isReadOnly
        textView.snippetLanguage = language
        textView.snippetFileName = fileName
        textView.onSnippetNotice = onSnippetNotice
        textView.onPasteIntoEmptyBuffer = onPasteIntoEmptyBuffer
        if textView.hasMarkedText() {
            context.coordinator.observeExternalTextDuringComposition(text)
        }
        // Restore stable source attributes before applying an external buffer.
        // Split-view attachment can clear NSTextView.typingAttributes even
        // though the coordinator still owns the intended editor palette.
        context.coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            language: language,
            settings: settings
        )
        let shouldApplyText =
            !context.coordinator.isApplyingText && !textView.hasMarkedText()
            && textView.string != text
        if shouldApplyText {
            context.coordinator.apply(text, to: textView)
        } else if documentChanged, !textView.hasMarkedText(), textView.string == text {
            // Identical source still represents a different document. Force a
            // fresh parse so stable block IDs remain scoped to their file.
            context.coordinator.refreshDocumentSnapshot(in: textView)
        }
        context.coordinator.repairInvisibleLaTeXSourceIfNeeded(in: textView)
        context.coordinator.ruler?.diagnostics = diagnostics
        context.coordinator.scrollToRequestedLine()
        context.coordinator.navigateToRequestedLocation()
        if language == .latex {
            container.scheduleViewportRepair()
        }
        if languageChanged, language == .latex {
            // Only restore first responder status when the source editor
            // previously owned it. Viewport repair is scheduled for every LaTeX
            // update and coalesced by the container.
            context.coordinator.restoreEditingAfterWorkspaceTransition(
                in: container,
                restoreFocus: shouldRestoreEditing
            )
        }
    }

    static func dismantleNSView(
        _ container: CodeEditorContainerView,
        coordinator: Coordinator
    ) {
        if let textView = container.scrollView.documentView as? CodeTextView {
            if textView.hasMarkedText() { textView.unmarkText() }
            // `unmarkText()` may deliver textDidChange synchronously or invoke
            // CodeTextView's deferred callback. Whichever path commits first
            // clears the composition session, so the other is a safe no-op.
            coordinator.compositionDidCommit()
        }
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
        private var markdownDocument: MarkdownDocumentSnapshot?
        private var syntaxTask: Task<Void, Never>?
        private var syntaxRevision = 0
        private var pendingSyntaxEdit: SyntaxEdit?
        private var needsPresentationRefreshAfterComposition = false
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
        private var markdownPublishTask: Task<Void, Never>?
        private var pendingMarkdownPublishRevision: UInt64?
        private var lastPublishedMarkdownRevision: UInt64?
        private var lastSynchronizedText: String
        private var compositionSession: TextCompositionSession?
        private var compositionBinding: Binding<String>?
        private var pendingSaveAfterComposition: (() -> Void)?
        fileprivate var documentIdentity: CodeEditorDocumentIdentity
        fileprivate var presentedLanguage: LanguageID
        fileprivate var isTextEditorActive = false
        private var focusRetirementGeneration = 0
        private var selectionReportGeneration = 0

        init(_ parent: CodeEditor) {
            self.parent = parent
            lastSynchronizedText = parent.text
            documentIdentity = parent.documentIdentity
            presentedLanguage = parent.language
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard notification.object is CodeTextView else { return }
            focusRetirementGeneration += 1
            isTextEditorActive = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard notification.object is CodeTextView else { return }
            focusRetirementGeneration += 1
            let generation = focusRetirementGeneration
            // A split-view reparent can briefly end editing in the same run-loop
            // turn as LaTeX promotion. Delay retirement so that transition can
            // reclaim focus, while a genuine click elsewhere clears the token
            // before any later language change.
            DispatchQueue.main.async { [weak self] in
                guard let self, focusRetirementGeneration == generation else { return }
                isTextEditorActive = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText, let textView = notification.object as? CodeTextView else {
                return
            }
            let value = textView.string
            rebuildLineIndex(for: value)
            if textView.hasMarkedText() {
                beginCompositionIfNeeded()
                needsPresentationRefreshAfterComposition = true
                pendingSyntaxEdit = nil
                ruler?.needsDisplay = true
                reportSelection(textView.selectedRange())
                return
            }
            if needsPresentationRefreshAfterComposition || compositionSession != nil {
                commitComposition(in: textView)
                return
            }
            parent.text = value
            lastSynchronizedText = value
            let edit = pendingSyntaxEdit
            pendingSyntaxEdit = nil
            applyVisibleBaseStyle(in: edit?.currentRange, to: textView)
            // Markdown presentation includes line-level hierarchy outside the exact edit.
            // Repaint the visible writing canvas after a formatting command so headings
            // and inline styles cannot be flattened by NSTextView's attributed replacement.
            scheduleHighlight(
                for: value,
                edit: parent.language == .markdown ? nil : edit,
                markdownEdit: edit
            )
            ruler?.needsDisplay = true
            reportSelection(textView.selectedRange())
        }

        fileprivate func compositionDidCommit() {
            guard needsPresentationRefreshAfterComposition || compositionSession != nil,
                let textView,
                !textView.hasMarkedText()
            else { return }
            commitComposition(in: textView)
        }

        private func beginCompositionIfNeeded() {
            guard compositionSession == nil else { return }
            compositionSession = TextCompositionSession(baseline: lastSynchronizedText)
            compositionBinding = parent.$text
        }

        fileprivate func observeExternalTextDuringComposition(_ value: String) {
            beginCompositionIfNeeded()
            compositionSession?.observeExternalText(value)
        }

        private func commitComposition(in textView: CodeTextView) {
            beginCompositionIfNeeded()
            if let currentModelValue = compositionBinding?.wrappedValue {
                compositionSession?.observeExternalText(currentModelValue)
            }
            let localValue = textView.string
            let resolvedValue =
                compositionSession?.resolve(committedLocalText: localValue) ?? localValue
            let binding = compositionBinding ?? parent.$text
            let deferredSave = pendingSaveAfterComposition
            compositionSession = nil
            compositionBinding = nil
            pendingSaveAfterComposition = nil
            needsPresentationRefreshAfterComposition = false
            pendingSyntaxEdit = nil

            if resolvedValue != localValue {
                apply(resolvedValue, to: textView)
            } else {
                lastSynchronizedText = resolvedValue
                rebuildLineIndex(for: resolvedValue)
            }
            if binding.wrappedValue != resolvedValue {
                binding.wrappedValue = resolvedValue
            }
            if let scrollView = textView.enclosingScrollView {
                updateAppearance(
                    textView: textView,
                    scrollView: scrollView,
                    theme: parent.theme,
                    language: parent.language,
                    settings: parent.settings
                )
            }
            applyVisibleBaseStyle(in: nil, to: textView)
            scheduleHighlight(for: resolvedValue)
            ruler?.needsDisplay = true
            reportSelection(textView.selectedRange())
            deferredSave?()
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
            // Carry the editor's explicit foreground and font into programmatic
            // updates. An unstyled attributed replacement defaults to black,
            // which is effectively invisible in Clip's dark editor.
            let replacementAttributes =
                textView.sourceTypingAttributes.isEmpty
                ? textView.typingAttributes : textView.sourceTypingAttributes
            let replacement = NSAttributedString(string: value, attributes: replacementAttributes)
            _ = textView.performValidatedReplacement(in: fullRange, with: replacement)
            manager?.enableUndoRegistration()
            let replacementLength = (value as NSString).length
            let selectionLocation = min(selection.location, replacementLength)
            textView.setSelectedRange(
                NSRange(
                    location: selectionLocation,
                    length: min(selection.length, replacementLength - selectionLocation)
                )
            )
            isApplyingText = false
            lastSynchronizedText = value
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

        func updateAppearance(
            textView: CodeTextView,
            scrollView: NSScrollView,
            theme: Theme,
            language: LanguageID,
            settings: EditorSettings
        ) {
            guard !textView.hasMarkedText() else {
                needsPresentationRefreshAfterComposition = true
                return
            }
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
            let typingAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraphStyle,
            ]
            textView.sourceTypingAttributes = typingAttributes
            textView.typingAttributes = typingAttributes
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
                // On a non-rich NSTextView these two convenience setters are
                // whole-document formatting commands. Reassigning them during
                // an unrelated SwiftUI update flattens heading fonts and makes
                // transparent Markdown delimiters visible. They are defaults
                // for an empty buffer only; populated storage is restyled by
                // the explicit attributed-string pipeline below.
                if textView.textStorage?.length == 0 {
                    textView.font = font
                    textView.textColor = foreground
                }
                applyVisibleBaseStyle(in: nil, to: textView)
                reapplyCachedMarkdownPresentation(to: textView)
                scheduleHighlight(for: textView.string)
            }
        }

        private func reapplyCachedMarkdownPresentation(to textView: NSTextView) {
            guard parent.language == .markdown, let document = markdownDocument,
                document.source == textView.string, let storage = textView.textStorage,
                storage.length > 0
            else { return }
            isApplyingSyntax = true
            storage.beginEditing()
            applyMarkdownPresentation(
                document: document,
                range: NSRange(location: 0, length: storage.length),
                storage: storage
            )
            storage.endEditing()
            isApplyingSyntax = false
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
            selectionReportGeneration += 1
            lineIndexTask?.cancel()
            lineIndexTask = nil
            syntaxTask?.cancel()
            syntaxTask = nil
            markdownPublishTask?.cancel()
            markdownPublishTask = nil
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = nil
        }

        fileprivate func restoreEditingAfterWorkspaceTransition(
            in container: CodeEditorContainerView,
            restoreFocus: Bool
        ) {
            container.scheduleViewportRepair()
            guard restoreFocus else { return }
            guard
                let expectedTextView = container.scrollView.documentView as? CodeTextView
            else { return }
            DispatchQueue.main.async { [weak self, weak container, weak expectedTextView] in
                guard let self, let container,
                    presentedLanguage == .latex, parent.language == .latex,
                    let textView = expectedTextView,
                    container.scrollView.documentView === textView,
                    let window = container.window
                else { return }
                window.makeFirstResponder(textView)
            }
        }

        @discardableResult
        fileprivate func transition(to identity: CodeEditorDocumentIdentity) -> Bool {
            guard documentIdentity != identity else { return false }
            documentIdentity = identity
            syntaxRevision += 1
            syntaxTask?.cancel()
            syntaxTask = nil
            markdownDocument = nil
            markdownPublishTask?.cancel()
            markdownPublishTask = nil
            pendingMarkdownPublishRevision = nil
            lastPublishedMarkdownRevision = nil
            pendingSyntaxEdit = nil
            needsPresentationRefreshAfterComposition = false
            compositionSession = nil
            compositionBinding = nil
            pendingSaveAfterComposition = nil
            lastSynchronizedText = parent.text
            return true
        }

        fileprivate func refreshDocumentSnapshot(in textView: NSTextView) {
            guard parent.language == .markdown else { return }
            scheduleHighlight(for: textView.string)
        }

        func save(_ currentText: String) {
            if let textView, textView.hasMarkedText() || compositionSession != nil {
                beginCompositionIfNeeded()
                pendingSaveAfterComposition = parent.onSave
                if textView.hasMarkedText() { textView.unmarkText() }
                compositionDidCommit()
                return
            }
            parent.text = currentText
            lastSynchronizedText = currentText
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
            selectionReportGeneration += 1
            let generation = selectionReportGeneration
            let identity = documentIdentity
            // NSTextView can report selection synchronously while SwiftUI is
            // reconciling this representable. Publish on the next run-loop turn
            // so cursor state never mutates its parent during a view update.
            DispatchQueue.main.async { [weak self] in
                guard let self, selectionReportGeneration == generation,
                    documentIdentity == identity
                else { return }
                let position = lineIndex.position(at: selection.location)
                parent.onSelectionChange(selection)
                parent.onCursorChange(position.line, position.column)
            }
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
            markdownEdit: SyntaxEdit? = nil,
            debounce: Bool = false
        ) {
            guard let textView else { return }
            _ = transition(to: parent.documentIdentity)
            guard !textView.hasMarkedText() else {
                needsPresentationRefreshAfterComposition = true
                return
            }
            syntaxRevision += 1
            let revision = syntaxRevision
            let language = parent.language
            let visibleRange = visibleCharacterRange(in: textView)
            let markdownDocument: MarkdownDocumentSnapshot?
            if language == .markdown {
                let document: MarkdownDocumentSnapshot
                if let previous = self.markdownDocument, let markdownEdit {
                    document = MarkdownBlockDocumentEngine.reconcile(
                        source: source,
                        with: previous,
                        edit: markdownEdit
                    )
                } else {
                    document = MarkdownBlockDocumentEngine.reconcile(
                        source: source,
                        with: self.markdownDocument
                    )
                }
                self.markdownDocument = document
                markdownDocument = document
                publishMarkdownDocument(document)
            } else {
                self.markdownDocument = nil
                markdownPublishTask?.cancel()
                markdownPublishTask = nil
                pendingMarkdownPublishRevision = nil
                lastPublishedMarkdownRevision = nil
                markdownDocument = nil
            }
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
                guard !textView.hasMarkedText() else {
                    needsPresentationRefreshAfterComposition = true
                    return
                }
                applySyntax(
                    result,
                    fencedCodeTokens: fencedCodeTokens,
                    markdownDocument: markdownDocument,
                    to: textView
                )
            }
        }

        private func publishMarkdownDocument(_ document: MarkdownDocumentSnapshot) {
            guard lastPublishedMarkdownRevision != document.revision,
                pendingMarkdownPublishRevision != document.revision
            else { return }
            markdownPublishTask?.cancel()
            pendingMarkdownPublishRevision = document.revision
            let identity = documentIdentity
            markdownPublishTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self,
                    documentIdentity == identity,
                    markdownDocument?.revision == document.revision,
                    markdownDocument?.source == document.source
                else { return }
                pendingMarkdownPublishRevision = nil
                lastPublishedMarkdownRevision = document.revision
                parent.onMarkdownDocumentChange(identity, document)
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
            markdownDocument: MarkdownDocumentSnapshot?,
            to textView: NSTextView
        ) {
            guard !textView.hasMarkedText() else {
                needsPresentationRefreshAfterComposition = true
                return
            }
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
            storage.removeAttribute(.kern, range: styledRange)
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
            if parent.language == .markdown, let markdownDocument {
                applyMarkdownPresentation(
                    document: markdownDocument,
                    range: styledRange,
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
            guard !textView.hasMarkedText() else {
                needsPresentationRefreshAfterComposition = true
                return
            }
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
            storage.removeAttribute(.kern, range: range)
            storage.addAttributes(attributes, range: range)
            isApplyingSyntax = false
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsDisplay = true
        }

        /// Repairs the failure mode where TextKit keeps the source buffer and
        /// selection but a split/layout transaction leaves one or more glyph
        /// runs transparent or indistinguishable from the editor background.
        /// The scan walks attribute runs and only repaints when corruption is
        /// present, so ordinary SwiftUI state updates remain inexpensive.
        fileprivate func repairInvisibleLaTeXSourceIfNeeded(in textView: NSTextView) {
            guard parent.language == .latex, !textView.hasMarkedText(),
                let storage = textView.textStorage, storage.length > 0
            else { return }
            let visibleRange = visibleCharacterRange(in: textView)
            let selectedLocation = min(textView.selectedRange().location, storage.length - 1)
            let selectedLine = (textView.string as NSString).lineRange(
                for: NSRange(location: selectedLocation, length: 0)
            )
            let background = textView.backgroundColor.usingColorSpace(.sRGB)
            func needsRepair(in range: NSRange) -> Bool {
                guard range.length > 0 else { return false }
                var needsRepair = false
                storage.enumerateAttribute(
                    .foregroundColor,
                    in: range,
                    options: [.longestEffectiveRangeNotRequired]
                ) { value, _, stop in
                    guard let color = value as? NSColor,
                        let foreground = color.usingColorSpace(.sRGB),
                        let background
                    else {
                        needsRepair = true
                        stop.pointee = true
                        return
                    }
                    let red = foreground.redComponent - background.redComponent
                    let green = foreground.greenComponent - background.greenComponent
                    let blue = foreground.blueComponent - background.blueComponent
                    let distance = (red * red + green * green + blue * blue).squareRoot()
                    if foreground.alphaComponent < 0.35 || distance < 0.16 {
                        needsRepair = true
                        stop.pointee = true
                    }
                }
                return needsRepair
            }
            var repaired = false
            if needsRepair(in: visibleRange) {
                applyVisibleBaseStyle(in: visibleRange, to: textView)
                repaired = true
            }
            if NSIntersectionRange(visibleRange, selectedLine).length == 0,
                needsRepair(in: selectedLine)
            {
                applyVisibleBaseStyle(in: selectedLine, to: textView)
                repaired = true
            }
            guard repaired else { return }
            scheduleHighlight(for: textView.string)
        }

        /// Paints one immutable block-document revision. Parsing and semantic
        /// decisions happen once in TextEngine; this bridge only maps typed
        /// blocks and inline runs to AppKit attributes.
        private func applyMarkdownPresentation(
            document: MarkdownDocumentSnapshot,
            range: NSRange,
            storage: NSTextStorage
        ) {
            guard document.source == storage.string,
                let syntaxBaseFont, let syntaxBaseColor, let markdownMarkerColor,
                let markdownCodeBackground, let markdownQuoteColor
            else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let safeRange = NSIntersectionRange(range, fullRange)
            guard safeRange.length > 0 else { return }

            func valid(_ requested: NSRange) -> NSRange? {
                let value = NSIntersectionRange(requested, fullRange)
                return value.length > 0 ? value : nil
            }

            for block in document.blocks
            where NSIntersectionRange(block.sourceRange, safeRange).length > 0 {
                let blockRange = valid(block.sourceRange)
                let contentRange = valid(block.contentRange)

                for syntaxRange in block.syntaxRanges {
                    guard let syntaxRange = valid(syntaxRange) else { continue }
                    storage.addAttributes(
                        markdownSyntaxAttributes(for: markdownMarkerColor),
                        range: syntaxRange
                    )
                }

                switch block.kind {
                case .heading(let requestedLevel):
                    for syntaxRange in block.syntaxRanges {
                        guard let syntaxRange = valid(syntaxRange) else { continue }
                        collapseMarkdownSyntax(in: syntaxRange, storage: storage)
                    }
                    guard let contentRange else { break }
                    let level = min(max(requestedLevel, 1), 6)
                    let scale: CGFloat = [1.78, 1.5, 1.28, 1.12, 1.04, 1.0][level - 1]
                    let paragraph =
                        (syntaxParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
                        ?? NSMutableParagraphStyle()
                    paragraph.paragraphSpacingBefore = level == 1 ? 18 : 12
                    paragraph.paragraphSpacing = level <= 2 ? 8 : 5
                    if let blockRange {
                        storage.addAttribute(
                            .paragraphStyle,
                            value: paragraph,
                            range: blockRange
                        )
                    }
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(
                                ofSize: max(
                                    syntaxBaseFont.pointSize * scale,
                                    syntaxBaseFont.pointSize
                                ),
                                weight: level <= 2 ? .bold : .semibold
                            ),
                            .foregroundColor: syntaxBaseColor,
                        ],
                        range: contentRange
                    )

                case .bulletedListItem, .numberedListItem, .taskItem:
                    for syntaxRange in block.syntaxRanges {
                        guard let syntaxRange = valid(syntaxRange) else { continue }
                        storage.addAttributes(
                            [
                                .foregroundColor: markdownQuoteColor,
                                .font: NSFont.systemFont(
                                    ofSize: syntaxBaseFont.pointSize,
                                    weight: .semibold
                                ),
                            ],
                            range: syntaxRange
                        )
                    }
                    if case .taskItem(isCompleted: true) = block.kind, let contentRange {
                        storage.addAttributes(
                            [
                                .foregroundColor: markdownMarkerColor,
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            ],
                            range: contentRange
                        )
                    }

                case .quote:
                    if let contentRange {
                        storage.addAttribute(
                            .foregroundColor,
                            value: markdownQuoteColor,
                            range: contentRange
                        )
                    }
                    if let blockRange {
                        let paragraph =
                            (syntaxParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
                            ?? NSMutableParagraphStyle()
                        paragraph.headIndent = 12
                        paragraph.firstLineHeadIndent = 0
                        paragraph.paragraphSpacing = 3
                        storage.addAttribute(
                            .paragraphStyle,
                            value: paragraph,
                            range: blockRange
                        )
                    }

                case .fencedCode:
                    if let blockRange {
                        storage.addAttributes(
                            [
                                .font: NSFont.monospacedSystemFont(
                                    ofSize: max(syntaxBaseFont.pointSize - 1, 10),
                                    weight: .regular
                                ),
                                .backgroundColor: markdownCodeBackground,
                            ],
                            range: blockRange
                        )
                    }

                case .math:
                    if let blockRange {
                        storage.addAttributes(
                            [
                                .font: NSFont.monospacedSystemFont(
                                    ofSize: syntaxBaseFont.pointSize,
                                    weight: .regular
                                ),
                                .foregroundColor: markdownQuoteColor,
                                .backgroundColor: markdownCodeBackground,
                            ],
                            range: blockRange
                        )
                    }

                case .table:
                    if let blockRange {
                        storage.addAttributes(
                            [
                                .font: NSFont.monospacedSystemFont(
                                    ofSize: max(syntaxBaseFont.pointSize - 1, 10),
                                    weight: .regular
                                ),
                                .backgroundColor: markdownCodeBackground.withAlphaComponent(0.55),
                            ],
                            range: blockRange
                        )
                    }

                case .divider:
                    if let contentRange {
                        storage.addAttributes(
                            [
                                .foregroundColor: markdownMarkerColor,
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            ],
                            range: contentRange
                        )
                    }

                case .paragraph, .empty, .raw:
                    break
                }

                for span in block.inlineSpans
                where NSIntersectionRange(span.contentRange, safeRange).length > 0 {
                    guard let contentRange = valid(span.contentRange) else { continue }
                    for syntaxRange in span.syntaxRanges {
                        guard let syntaxRange = valid(syntaxRange) else { continue }
                        collapseMarkdownSyntax(in: syntaxRange, storage: storage)
                    }
                    switch span.kind {
                    case .strong:
                        let current =
                            storage.attribute(.font, at: contentRange.location, effectiveRange: nil)
                            as? NSFont ?? syntaxBaseFont
                        storage.addAttribute(
                            .font,
                            value: NSFontManager.shared.convert(
                                current,
                                toHaveTrait: .boldFontMask
                            ),
                            range: contentRange
                        )
                    case .emphasis:
                        let current =
                            storage.attribute(.font, at: contentRange.location, effectiveRange: nil)
                            as? NSFont ?? syntaxBaseFont
                        storage.addAttribute(
                            .font,
                            value: NSFontManager.shared.convert(
                                current,
                                toHaveTrait: .italicFontMask
                            ),
                            range: contentRange
                        )
                    case .strikethrough:
                        storage.addAttribute(
                            .strikethroughStyle,
                            value: NSUnderlineStyle.single.rawValue,
                            range: contentRange
                        )
                    case .code:
                        storage.addAttributes(
                            [
                                .font: NSFont.monospacedSystemFont(
                                    ofSize: max(syntaxBaseFont.pointSize - 1, 10),
                                    weight: .regular
                                ),
                                .backgroundColor: markdownCodeBackground,
                            ],
                            range: contentRange
                        )
                    case .link:
                        storage.addAttributes(
                            [
                                .foregroundColor: markdownQuoteColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue,
                                .underlineColor: markdownQuoteColor,
                            ],
                            range: contentRange
                        )
                    case .math:
                        storage.addAttributes(
                            [
                                .font: NSFont.monospacedSystemFont(
                                    ofSize: max(syntaxBaseFont.pointSize - 1, 10),
                                    weight: .regular
                                ),
                                .foregroundColor: markdownQuoteColor,
                            ],
                            range: contentRange
                        )
                    }
                }
            }
        }

        private func markdownSyntaxAttributes(
            for color: NSColor
        ) -> [NSAttributedString.Key: Any] {
            // Syntax never changes glyph metrics. Stable metrics keep TextKit's
            // caret, hit testing, IME ranges, and selections aligned with source.
            return [
                .foregroundColor: color,
                .font: syntaxBaseFont ?? NSFont.systemFont(ofSize: 13),
            ]
        }

        /// Hides a source delimiter without changing the line's font metrics.
        /// Negative kerning cancels each glyph's advance while the normal font
        /// keeps TextKit's baseline, hit testing, and IME geometry stable.
        private func collapseMarkdownSyntax(
            in range: NSRange,
            storage: NSTextStorage
        ) {
            guard let font = syntaxBaseFont, range.length > 0,
                NSMaxRange(range) <= storage.length
            else { return }
            storage.addAttributes(
                [.foregroundColor: NSColor.clear, .font: font],
                range: range
            )
            let source = storage.string as NSString
            var location = range.location
            while location < NSMaxRange(range) {
                let characterRange = source.rangeOfComposedCharacterSequence(at: location)
                let bounded = NSIntersectionRange(characterRange, range)
                guard bounded.length > 0 else { break }
                let value = source.substring(with: bounded)
                let width = (value as NSString).size(withAttributes: [.font: font]).width
                storage.addAttribute(.kern, value: -width, range: bounded)
                location = NSMaxRange(bounded)
            }
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
