import AppKit
import ConvertKit
import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI
import TextEngine
import UniformTypeIdentifiers

struct TextEditorWorkspace: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: TextEditorViewModel
    @State private var cursorLine = 1
    @State private var cursorColumn = 1
    @State private var showsExternalConflictAlert = false
    @State private var showsExternalDiff = false
    @State private var sourceNavigation: TextEditorNavigation?
    @State private var texForwardSearch: TeXForwardSearchRequest?
    @State private var showsTeXOutput = false
    @State private var texOutputTab: TeXOutputTab = .problems
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var markdownDocument: MarkdownDocumentSnapshot?
    @State private var markdownDocumentIdentity: CodeEditorDocumentIdentity?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if editor.language == .markdown {
                    Divider().overlay(theme.palette.line)
                    markdownFormattingBar
                }
                Divider().overlay(theme.palette.line)
                if editor.isDetached {
                    detachedBanner
                    Divider().overlay(theme.palette.line)
                } else if editor.hasExternalConflict {
                    externalConflictBanner
                    Divider().overlay(theme.palette.line)
                } else if editor.isReadOnly {
                    readOnlyBanner
                    Divider().overlay(theme.palette.line)
                }
                editorSurface
                if editor.language == .latex, showsTeXOutput {
                    Divider().overlay(theme.palette.line)
                    TeXDiagnosticsPanel(
                        diagnostics: editor.texDiagnostics,
                        log: editor.texLog,
                        selectedTab: $texOutputTab,
                        onSelectDiagnostic: navigateToDiagnostic,
                        onClose: { showsTeXOutput = false }
                    )
                }
                Divider().overlay(theme.palette.line)
                statusBar
            }
            if let notice = editor.notice {
                Toast(notice)
                    .padding(.bottom, theme.metrics.spacing.xxl)
                    .task(id: notice) {
                        do {
                            try await Task.sleep(for: .seconds(2.1))
                        } catch {
                            return
                        }
                        editor.clearNotice()
                    }
            }
        }
        .background(theme.palette.surfaceBase)
        .onChange(of: editor.hasExternalConflict, initial: true) { _, hasConflict in
            if hasConflict { showsExternalConflictAlert = true }
        }
        .onChange(of: editor.texDiagnostics) { _, diagnostics in
            guard !diagnostics.isEmpty else { return }
            texOutputTab = .problems
            showsTeXOutput = true
        }
        .onChange(of: editor.texCompilationState) { _, state in
            if case .failed = state, editor.texDiagnostics.isEmpty, !editor.texLog.isEmpty {
                texOutputTab = .log
                showsTeXOutput = true
            }
        }
        .alert("File Changed on Disk", isPresented: $showsExternalConflictAlert) {
            Button("Keep Mine", action: editor.keepCurrentVersion)
            Button("Use Disk Version", role: .destructive, action: editor.useExternalVersion)
            Button("Compare…") { showsExternalDiff = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved edits. Choose which version to keep, or compare them first.")
        }
        .sheet(isPresented: $showsExternalDiff) {
            if let external = editor.pendingExternalContents {
                ExternalTextComparisonView(editor: editor, externalText: external.text)
                    .environment(\.theme, theme)
            }
        }
        .alert(
            "Allow LaTeX Package Downloads?",
            isPresented: Binding(
                get: { editor.needsTeXPackageConsent },
                set: { if !$0 { editor.cancelTeXPackageConsent() } }
            )
        ) {
            Button("Cached packages only") {
                editor.resolveTeXPackageConsent(allowNetwork: false)
            }
            Button("Allow downloads") {
                editor.resolveTeXPackageConsent(allowNetwork: true)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel, action: editor.cancelTeXPackageConsent)
        } message: {
            Text(
                "Tectonic may need to download LaTeX packages. Clip records each allowed fetch in the egress ledger. You can keep compilation offline and use only cached packages instead."
            )
        }
    }

    private var editorSurface: some View {
        // Keep the native text editor under one stable split-view hierarchy.
        // Automatic language detection can promote a scratch buffer to LaTeX
        // while AppKit is still delivering a key sequence. Replacing a lone
        // CodeEditor with a new HSplitView at that moment destroys the first
        // responder and drops the remaining characters.
        HSplitView {
            if editor.language == .latex, editor.document.files.count > 1 {
                TeXProjectSidebar(editor: editor)
                    .frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
            }
            codeEditor
                .frame(minWidth: editor.language == .latex ? 340 : 0)
            if editor.language == .latex {
                TeXPDFPreview(
                    editor: editor,
                    forwardSearch: texForwardSearch,
                    onInverseSearch: runInverseSearch
                )
                .frame(minWidth: 340)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(editorSurfaceAccessibilityIdentifier)
    }

    private var editorSurfaceAccessibilityIdentifier: String {
        switch editor.language {
        case .latex: "latex-split-editor"
        case .markdown: "markdown-inline-editor"
        default: "text-source-editor"
        }
    }

    private var codeEditor: some View {
        ZStack(alignment: .topLeading) {
            CodeEditor(
                text: $editor.text,
                language: editor.language,
                settings: editor.settings,
                documentIdentity: editorDocumentIdentity,
                fileName: editor.activeFile?.relativePath ?? "Untitled.txt",
                isReadOnly: editor.isReadOnly,
                undoManager: editor.undoManager,
                onSave: editor.saveNow,
                onLongLineModeChange: editor.setSoftWrapSuppressed,
                onLargePaste: editor.enterLargePasteReadOnlyMode,
                onPasteRefused: editor.reportPasteRefused,
                onPasteIntoEmptyBuffer: editor.detectPastedLanguage,
                onSnippetNotice: editor.reportNotice,
                diagnostics: editor.language == .latex ? activeFileDiagnostics : [],
                scrollToLine: nil,
                navigation: sourceNavigation,
                onVisibleLineChange: { _ in },
                onSelectionChange: { selectedRange = $0 },
                onMarkdownDocumentChange: { identity, document in
                    guard identity == editorDocumentIdentity,
                        document.source == editor.text
                    else { return }
                    markdownDocumentIdentity = identity
                    markdownDocument = document
                }
            ) { line, column in
                cursorLine = line
                cursorColumn = column
            }
            if editor.text.isEmpty {
                Text("Start typing…")
                    .font(theme.type.body.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .padding(
                        .leading,
                        editor.language == .plainText || editor.language == .markdown ? 28 : 72
                    )
                    .padding(.top, 20)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: theme.metrics.spacing.sm) {
            Button(action: model.closeTextEditor) {
                HStack(spacing: theme.metrics.spacing.sm) {
                    Image(systemName: "chevron.left")
                    Text("Text library")
                }
                .frame(height: 28)
                .padding(.horizontal, theme.metrics.spacing.sm)
            }
            .buttonStyle(ReelIconButtonStyle())
            .help("Back to text library")

            Rectangle()
                .fill(theme.palette.line)
                .frame(width: theme.metrics.hairline, height: 18)

            EditableFileTitle(
                name: activeFilename,
                accessibilityIdentifier: "text-file-title",
                onCommit: model.renameOpenTextFile
            )

            Rectangle()
                .fill(theme.palette.line)
                .frame(width: theme.metrics.hairline, height: 18)

            languageMenu

            Spacer()

            snippetMenu

            if editor.language == .markdown {
                Menu {
                    ForEach(model.textEditorExportTargets) { target in
                        Button(target.displayName) {
                            model.enqueueTextEditorExport(as: target)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.textEditorExportTargets.isEmpty)
                .help("Export through Clip's conversion queue")
                .accessibilityIdentifier("markdown-export")
            }

            if editor.language == .latex {
                Button(action: runForwardSearch) {
                    Label("Locate in PDF", systemImage: "arrow.right.doc.on.clipboard")
                }
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.texSyncTeXIndex == nil)
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .help("Locate the current source line in the PDF (Command-Shift-J)")
                .accessibilityIdentifier("latex-forward-search")

                Button {
                    texOutputTab = editor.texDiagnostics.isEmpty ? .log : .problems
                    showsTeXOutput.toggle()
                } label: {
                    Label(
                        editor.texDiagnostics.isEmpty
                            ? "Build Log" : "Problems \(editor.texDiagnostics.count)",
                        systemImage: "exclamationmark.bubble"
                    )
                }
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.texLog.isEmpty && editor.texDiagnostics.isEmpty)
                .help("Show diagnostics and raw engine output")
                .accessibilityIdentifier("latex-build-output-toggle")

                Menu {
                    Button("Automatic") { editor.setTeXCompileMode(.automatic) }
                    Button("On Save") { editor.setTeXCompileMode(.onSave) }
                    Button("Manual") { editor.setTeXCompileMode(.manual) }
                } label: {
                    Label(editor.texCompileMode.editorTitle, systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose when LaTeX recompiles")

                if editor.texCompilationState == .compiling {
                    ProgressView()
                        .controlSize(.small)
                    Button(action: editor.cancelTeXCompilation) {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(ReelIconButtonStyle())
                    .help("Stop compilation")
                    .accessibilityIdentifier("latex-cancel")
                } else {
                    Button(action: editor.requestTeXCompile) {
                        Label("Build", systemImage: "hammer")
                    }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .keyboardShortcut("b", modifiers: .command)
                    .help("Compile LaTeX (Command-B)")
                    .accessibilityIdentifier("latex-compile")
                }
            }

            saveControl

            Button(action: editor.undo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(isRenamingOpenFile || !editor.undoManager.canUndo)
            .help("Undo")

            Button(action: editor.redo) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(isRenamingOpenFile || !editor.undoManager.canRedo)
            .help("Redo")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: EditorChromeMetrics.headerHeight)
        .background(theme.palette.surfacePanel)
    }

    private var activeFilename: String {
        editor.activeFile?.assetID.flatMap { assetID in
            model.assets.first(where: { $0.id == assetID })?.displayName
        } ?? editor.activeFile?.relativePath ?? "Untitled.txt"
    }

    private var editorDocumentIdentity: CodeEditorDocumentIdentity {
        CodeEditorDocumentIdentity(
            documentID: editor.document.id,
            fileID: editor.activeFileID
        )
    }

    private var isRenamingOpenFile: Bool {
        editor.document.files.contains { file in
            file.assetID.map(model.renamingAssetIDs.contains) == true
        }
    }

    private var languageMenu: some View {
        Menu {
            Button {
                editor.enableAutomaticLanguageDetection()
            } label: {
                if editor.activeFile?.languageIsExplicit == false {
                    Label("Detect Automatically", systemImage: "checkmark")
                } else {
                    Text("Detect Automatically")
                }
            }
            Divider()
            languageButton("Plain Text", language: .plainText)
            languageButton("Markdown", language: .markdown)
            languageButton("LaTeX", language: .latex)
            Divider()
            languageButton("Swift", language: .swift)
            languageButton("JavaScript", language: .javascript)
            languageButton("TypeScript", language: .typescript)
            languageButton("Python", language: .python)
            languageButton("JSON", language: .json)
            languageButton("HTML", language: .html)
            languageButton("CSS", language: .css)
            languageButton("SQL", language: .sql)
            languageButton("Shell", language: .bash)
        } label: {
            HStack(spacing: 6) {
                Image(
                    systemName: editor.activeFile?.languageIsExplicit == false
                        ? "sparkles" : (editor.language == .latex ? "function" : "textformat")
                )
                Text(editor.language.editorDisplayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(theme.palette.surfaceRaised)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            editor.activeFile?.languageIsExplicit == false
                ? "Detected automatically from what you type" : "Choose document language"
        )
        .accessibilityLabel(
            editor.activeFile?.languageIsExplicit == false
                ? "Language: \(editor.language.editorDisplayName), detected automatically"
                : "Language: \(editor.language.editorDisplayName)"
        )
        .accessibilityIdentifier("text-language-menu")
    }

    private func languageButton(_ title: String, language: LanguageID) -> some View {
        Button {
            editor.setLanguage(language)
        } label: {
            if editor.language == language {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var markdownFormattingBar: some View {
        HStack(spacing: theme.metrics.spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                markdownFormattingControls
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityLabel("Markdown formatting")

            ViewThatFits(in: .horizontal) {
                Label("Live formatting", systemImage: "sparkles")
                Image(systemName: "sparkles")
                    .accessibilityLabel("Markdown formats live as you type")
            }
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textTertiary)
            .fixedSize()
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 44)
        .background(theme.palette.surfacePanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-formatting-toolbar")
    }

    private var markdownFormattingControls: some View {
        let document = markdownDocument.flatMap { snapshot in
            markdownDocumentIdentity == editorDocumentIdentity
                && snapshot.source == editor.text
                ? snapshot : nil
        }
        let blockStyle =
            document.map {
                MarkdownFormattingOperations.blockStyle(
                    in: $0,
                    selectedRange: selectedRange
                )
            } ?? .body
        let inlineActions: [MarkdownFormattingAction] = [
            .bold, .italic, .strikethrough, .inlineCode, .link, .inlineMath,
        ]
        let activeInlineStyles = Set(
            document.map { document in
                inlineActions.filter {
                    MarkdownFormattingOperations.isInlineStyleActive(
                        $0,
                        in: document,
                        selectedRange: selectedRange
                    )
                }
            } ?? []
        )
        return HStack(spacing: 4) {
            Menu {
                markdownBlockMenuButton(
                    "Body", style: .body, currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownBody(_:)))
                markdownBlockMenuButton(
                    "Heading 1", style: .heading(1), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading1(_:)))
                markdownBlockMenuButton(
                    "Heading 2", style: .heading(2), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading2(_:)))
                markdownBlockMenuButton(
                    "Heading 3", style: .heading(3), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading3(_:)))
                Divider()
                markdownBlockMenuButton(
                    "Heading 4", style: .heading(4), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading4(_:)))
                markdownBlockMenuButton(
                    "Heading 5", style: .heading(5), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading5(_:)))
                markdownBlockMenuButton(
                    "Heading 6", style: .heading(6), currentStyle: blockStyle,
                    action: #selector(CodeTextView.markdownHeading6(_:)))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                    Text(blockStyle.displayName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(theme.palette.surfaceRaised)
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Turn the current line into body text or a heading")
            .accessibilityLabel(blockStyle.displayName)
            .accessibilityIdentifier("markdown-block-style")

            formattingDivider

            markdownFormatButton(
                "Bold",
                systemImage: "bold",
                action: #selector(CodeTextView.markdownBold(_:)),
                identifier: "markdown-bold",
                isActive: activeInlineStyles.contains(.bold)
            )
            markdownFormatButton(
                "Italic",
                systemImage: "italic",
                action: #selector(CodeTextView.markdownItalic(_:)),
                identifier: "markdown-italic",
                isActive: activeInlineStyles.contains(.italic)
            )
            markdownFormatButton(
                "Strikethrough",
                systemImage: "strikethrough",
                action: #selector(CodeTextView.markdownStrikethrough(_:)),
                identifier: "markdown-strikethrough",
                isActive: activeInlineStyles.contains(.strikethrough)
            )
            markdownFormatButton(
                "Inline code",
                systemImage: "chevron.left.forwardslash.chevron.right",
                action: #selector(CodeTextView.markdownInlineCode(_:)),
                identifier: "markdown-inline-code",
                isActive: activeInlineStyles.contains(.inlineCode)
            )
            markdownFormatButton(
                "Link",
                systemImage: "link",
                action: #selector(CodeTextView.markdownLink(_:)),
                identifier: "markdown-link",
                isActive: activeInlineStyles.contains(.link)
            )
            markdownFormatButton(
                "Inline math",
                systemImage: "function",
                action: #selector(CodeTextView.markdownInlineMath(_:)),
                identifier: "markdown-inline-math",
                isActive: activeInlineStyles.contains(.inlineMath)
            )

            formattingDivider

            markdownFormatButton(
                "Bulleted list",
                systemImage: "list.bullet",
                action: #selector(CodeTextView.markdownBulletedList(_:)),
                identifier: "markdown-bulleted-list",
                isActive: blockStyle == .bulletedList
            )
            markdownFormatButton(
                "Numbered list",
                systemImage: "list.number",
                action: #selector(CodeTextView.markdownNumberedList(_:)),
                identifier: "markdown-numbered-list",
                isActive: blockStyle == .numberedList
            )
            markdownFormatButton(
                "Checklist",
                systemImage: "checklist",
                action: #selector(CodeTextView.markdownChecklist(_:)),
                identifier: "markdown-checklist",
                isActive: blockStyle == .checklist
            )
            markdownFormatButton(
                "Quote",
                systemImage: "text.quote",
                action: #selector(CodeTextView.markdownQuote(_:)),
                identifier: "markdown-quote",
                isActive: blockStyle == .quote
            )

            Menu {
                Button("Code block") {
                    sendMarkdownAction(#selector(CodeTextView.markdownCodeBlock(_:)))
                }
                Button("Table") {
                    sendMarkdownAction(#selector(CodeTextView.markdownTable(_:)))
                }
                Button("Image") {
                    sendMarkdownAction(#selector(CodeTextView.markdownImage(_:)))
                }
                Button("Footnote") {
                    sendMarkdownAction(#selector(CodeTextView.markdownFootnote(_:)))
                }
                Button("Math block") {
                    sendMarkdownAction(#selector(CodeTextView.markdownMathBlock(_:)))
                }
                Divider()
                Button("Divider") {
                    sendMarkdownAction(#selector(CodeTextView.markdownDivider(_:)))
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Insert code, a table, image, footnote, math, or divider")
            .accessibilityLabel("Insert Markdown block")
            .accessibilityIdentifier("markdown-insert-block")
        }
    }

    private var formattingDivider: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(width: theme.metrics.hairline, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private func markdownFormatButton(
        _ title: String,
        systemImage: String,
        action: Selector,
        identifier: String,
        isActive: Bool = false
    ) -> some View {
        Button {
            sendMarkdownAction(action)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ReelIconButtonStyle(isActive: isActive))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func markdownBlockMenuButton(
        _ title: String,
        style: MarkdownBlockStyle,
        currentStyle: MarkdownBlockStyle,
        action: Selector
    ) -> some View {
        Button {
            sendMarkdownAction(action)
        } label: {
            if currentStyle == style {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func sendMarkdownAction(_ action: Selector) {
        if !NSApp.sendAction(action, to: nil, from: nil) {
            editor.reportNotice("Click in the writing canvas before formatting text.")
        }
    }

    private func runForwardSearch() {
        guard let location = editor.forwardTeXSearch(line: cursorLine) else { return }
        texForwardSearch = TeXForwardSearchRequest(location: location)
    }

    private var snippetMenu: some View {
        Menu {
            Group {
                Button("Copy as Rich Text") {
                    sendSnippetAction(#selector(CodeTextView.copyAsRichText(_:)))
                }
                Button("Copy as HTML") {
                    sendSnippetAction(#selector(CodeTextView.copyAsHTML(_:)))
                }
                Button("Copy with Line Numbers") {
                    sendSnippetAction(#selector(CodeTextView.copyWithLineNumbers(_:)))
                }
                Button("Copy with File and Lines") {
                    sendSnippetAction(#selector(CodeTextView.copyAnnotated(_:)))
                }
            }
            .disabled(selectedRange.length == 0)

            Divider()

            Button("Wrap in Code Fence") {
                sendSnippetAction(#selector(CodeTextView.wrapInCodeFence(_:)))
            }
            .disabled(selectedRange.length == 0 || editor.isReadOnly)
            Button("Export as HTML…", action: presentHTMLExportPanel)
        } label: {
            Image(systemName: "doc.on.clipboard")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(selectedRange.length == 0 && editor.text.isEmpty)
        .help("Copy snippets or export this file")
        .accessibilityLabel("Snippet actions")
        .accessibilityIdentifier("text-snippet-menu")
    }

    private func sendSnippetAction(_ action: Selector) {
        if !NSApp.sendAction(action, to: nil, from: nil) {
            editor.reportNotice("Click in the editor before using a snippet command.")
        }
    }

    private func presentHTMLExportPanel() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        let sourceName = editor.activeFile?.relativePath ?? "Untitled"
        panel.nameFieldStringValue =
            URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent + ".html"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exportStandaloneHTML(to: url)
        }
    }

    private func exportStandaloneHTML(to url: URL) {
        let source = editor.text
        let language = editor.language
        let title = editor.activeFile?.relativePath ?? "Untitled"
        Task { @MainActor in
            let highlighter = SyntaxHighlighter()
            let result = await highlighter.highlights(
                in: source,
                language: language,
                visibleRange: NSRange(location: 0, length: (source as NSString).length)
            )
            let attributed = TextSnippetOperations.attributedString(
                source: source,
                tokens: result.tokens
            )
            let html = TextSnippetOperations.standaloneHTML(
                title: title,
                attributedString: attributed
            )
            let data = Data(html.utf8)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                }.value
                editor.reportNotice("Exported \(url.lastPathComponent).")
            } catch {
                editor.reportNotice("The HTML file could not be exported.")
            }
        }
    }

    private func runInverseSearch(page: Int, x: Double, y: Double) {
        guard let location = editor.inverseTeXSearch(page: page, x: x, y: y) else { return }
        editor.selectFile(relativePath: location.file)
        sourceNavigation = TextEditorNavigation(
            line: location.line,
            column: location.column ?? 1
        )
    }

    private func navigateToDiagnostic(_ diagnostic: TeXDiagnostic) {
        guard let line = diagnostic.line else { return }
        if let file = diagnostic.file { editor.selectFile(relativePath: file) }
        sourceNavigation = TextEditorNavigation(line: line)
    }

    private var activeFileDiagnostics: [TeXDiagnostic] {
        return editor.texDiagnostics.filter { diagnostic in
            guard let file = diagnostic.file else { return true }
            return editor.isActiveFile(path: file)
        }
    }

    private var detachedBanner: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backing file unavailable")
                    .font(theme.type.label.font)
                Text("The buffer is safe in memory. Save a copy before closing.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer()
            Button("Save As…", action: presentDetachedSavePanel)
                .buttonStyle(ReelBorderedButtonStyle())
                .accessibilityIdentifier("text-detached-save-as")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(minHeight: 52)
        .background(theme.palette.surfaceRaised)
    }

    private var externalConflictBanner: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.palette.textSecondary)
            Text("This file changed on disk while you were editing.")
                .font(theme.type.label.font)
            Spacer()
            Button("Review") { showsExternalConflictAlert = true }
                .buttonStyle(ReelBorderedButtonStyle())
                .accessibilityIdentifier("text-external-change-review")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(minHeight: 44)
        .background(theme.palette.surfaceRaised)
    }

    private var readOnlyBanner: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: "doc.badge.ellipsis")
                .foregroundStyle(theme.palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Large paste opened read-only")
                    .font(theme.type.label.font)
                Text("Pastes over 2 MB are protected from expensive live editing.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(minHeight: 52)
        .background(theme.palette.surfaceRaised)
    }

    private func presentDetachedSavePanel() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = editor.activeFile?.relativePath ?? "Untitled.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.saveDetachedCopy(to: url)
        }
    }

    @ViewBuilder private var saveControl: some View {
        if editor.isDirty {
            Button(action: editor.saveNow) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ReelProminentButtonStyle())
            .help("Save now")
            .accessibilityIdentifier("text-save")
        } else {
            Label("Saved", systemImage: "checkmark")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(minWidth: 58, minHeight: 28, alignment: .trailing)
                .accessibilityLabel("All changes saved")
        }
    }

    private var statusBar: some View {
        HStack(spacing: theme.metrics.spacing.lg) {
            Text("Ln \(cursorLine), Col \(cursorColumn)")
            Spacer()
            statusItem(editor.activeFile?.encoding.editorDisplayName ?? "UTF-8")
            statusDivider
            statusItem(editor.activeFile?.lineEnding.editorDisplayName ?? "LF")
            statusDivider
            statusItem(editor.settings.softWrap ? "Wrap" : "No wrap")
            if editor.language == .markdown {
                statusDivider
                statusItem("Inline Markdown")
            }
            if editor.language == .latex {
                statusDivider
                statusItem(editor.texCompilationState.statusTitle)
            }
        }
        .font(theme.type.numeric.font)
        .foregroundStyle(theme.palette.textTertiary)
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 28)
        .background(theme.palette.surfacePanel)
    }

    private func statusItem(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .fixedSize()
    }

    private var statusDivider: some View {
        Circle()
            .fill(theme.palette.textTertiary.opacity(0.55))
            .frame(width: 2, height: 2)
            .accessibilityHidden(true)
    }
}

extension TeXCompileMode {
    fileprivate var editorTitle: String {
        switch self {
        case .automatic: "Automatic"
        case .onSave: "On Save"
        case .manual: "Manual"
        }
    }
}

extension TeXCompilationState {
    fileprivate var statusTitle: String {
        switch self {
        case .idle: "Not built"
        case .compiling: "Building"
        case .succeeded: "PDF ready"
        case .paused: "Auto-build paused"
        case .failed: "Build failed"
        }
    }
}

extension TextEncoding {
    var editorDisplayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf16LittleEndian: "UTF-16 LE"
        case .isoLatin1: "ISO Latin-1"
        case .windowsLatin1: "Windows Latin-1"
        case .macRoman: "Mac Roman"
        case .ascii: "ASCII"
        }
    }
}

extension LineEnding {
    var editorDisplayName: String { rawValue.uppercased() }
}

extension LanguageID {
    var editorDisplayName: String {
        switch self {
        case .plainText: "Plain Text"
        case .cpp: "C++"
        case .css: "CSS"
        case .html: "HTML"
        case .json: "JSON"
        case .sql: "SQL"
        case .xml: "XML"
        case .yaml: "YAML"
        default: rawValue.capitalized
        }
    }
}

private struct ExternalTextComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel
    let externalText: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare Versions")
                        .font(theme.type.title.font)
                    Text("Review your unsaved buffer beside the current file on disk.")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                    .buttonStyle(ReelBorderedButtonStyle())
                Button("Keep Mine") {
                    editor.keepCurrentVersion()
                    dismiss()
                }
                .buttonStyle(ReelBorderedButtonStyle())
                Button("Use Disk Version") {
                    editor.useExternalVersion()
                    dismiss()
                }
                .buttonStyle(ReelProminentButtonStyle())
            }
            .padding(theme.metrics.spacing.lg)

            Divider().overlay(theme.palette.line)

            HStack(spacing: 0) {
                comparisonColumn(title: "My Unsaved Version", text: editor.text)
                Divider().overlay(theme.palette.line)
                comparisonColumn(title: "Version on Disk", text: externalText)
            }
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 520, idealHeight: 620)
        .background(theme.palette.surfaceBase)
    }

    private func comparisonColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, theme.metrics.spacing.lg)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(theme.palette.surfacePanel)
            Divider().overlay(theme.palette.line)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(theme.metrics.spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
