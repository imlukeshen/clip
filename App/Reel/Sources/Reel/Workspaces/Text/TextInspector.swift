import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI
import TextEngine

struct TextInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: TextEditorViewModel
    @State private var panel = Panel.inspector

    private enum Panel: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case chat = "Chat"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .frame(height: EditorChromeMetrics.headerHeight)
            Divider().overlay(theme.palette.line)

            if panel == .inspector {
                inspector
            } else {
                chat
            }
        }
        .accessibilityIdentifier("text-inspector")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.metrics.spacing.sm) {
                Text("Text")
                    .font(theme.type.title.font)
                Spacer()
                Image(systemName: "textformat")
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(.horizontal, theme.metrics.spacing.lg)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xxl) {
                    documentSection
                    if editor.language == .latex {
                        latexSection
                    }
                    editorSection
                }
                .padding(theme.metrics.spacing.lg)
            }
            .scrollIndicators(.visible)
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if model.assistantMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Text context")
                                    .font(theme.type.label.font)
                                Text(
                                    "Ask Clip to inspect LaTeX errors, format source, search the library, or prepare an export."
                                )
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.textTertiary)
                            }
                        }
                        ForEach(model.assistantMessages) { message in
                            AssistantChatBubble(message: message)
                                .id(message.id)
                        }
                        ForEach(model.pendingAssistantActions) { action in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(action.result.message)
                                    .font(theme.type.caption.font)
                                HStack {
                                    Button("Apply") { model.approveAssistantAction(action.id) }
                                    Button("Skip") { model.rejectAssistantAction(action.id) }
                                }
                            }
                            .padding(10)
                            .background(theme.palette.surfaceRaised)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: theme.metrics.radius.control,
                                    style: .continuous
                                )
                            )
                        }
                        if model.isAssistantWorking { ProgressView().controlSize(.small) }
                    }
                    .padding(14)
                }
                .onChange(of: model.assistantMessages.count) {
                    if let id = model.assistantMessages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            AssistantChatComposer(
                draft: $model.assistantDraft,
                isWorking: model.isAssistantWorking,
                send: model.sendAssistantMessage
            )
        }
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            sectionHeader("Document", symbol: "doc.text")

            inspectorCard {
                valueRow(
                    title: "File",
                    value: editor.activeFile?.relativePath ?? "Untitled.txt",
                    symbol: "doc"
                )

                rowDivider

                HStack(spacing: theme.metrics.spacing.md) {
                    documentFact(
                        title: "Encoding",
                        value: editor.activeFile?.encoding.editorDisplayName ?? "UTF-8"
                    )
                    Rectangle()
                        .fill(theme.palette.line)
                        .frame(width: theme.metrics.hairline, height: 28)
                    documentFact(
                        title: "Line endings",
                        value: editor.activeFile?.lineEnding.editorDisplayName ?? "LF"
                    )
                }
                .padding(.horizontal, theme.metrics.spacing.md)
                .padding(.vertical, theme.metrics.spacing.md)

                if editor.activeFile?.lineEnding == .mixed {
                    rowDivider
                    lineEndingMenu
                }

                rowDivider

                languageMenu
            }
        }
    }

    private var latexSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            sectionHeader("LaTeX project", symbol: "doc.on.doc")

            inspectorCard {
                valueRow(
                    title: "Main file",
                    value: editor.mainFile?.relativePath ?? "Not selected",
                    symbol: "target"
                )
                rowDivider
                valueRow(
                    title: "Bibliography",
                    value: editor.texProjectAnalysis?.bibliography.inspectorTitle ?? "None",
                    symbol: "books.vertical"
                )
                if let analysis = editor.texProjectAnalysis,
                    !analysis.missingDependencies.isEmpty
                {
                    rowDivider
                    valueRow(
                        title: "Missing files",
                        value: "\(analysis.missingDependencies.count)",
                        symbol: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private var lineEndingMenu: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon("arrow.left.arrow.right")
            VStack(alignment: .leading, spacing: 2) {
                Text("Mixed line endings")
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Choose a format to normalize")
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer(minLength: theme.metrics.spacing.sm)
            Menu("Normalize") {
                Button("LF") { editor.normalizeLineEndings(to: .lf) }
                Button("CRLF") { editor.normalizeLineEndings(to: .crlf) }
                Button("CR") { editor.normalizeLineEndings(to: .cr) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(minHeight: 50)
        .accessibilityIdentifier("text-normalize-line-endings")
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            sectionHeader("Editor", symbol: "slider.horizontal.3")

            inspectorCard {
                toggleRow(
                    title: "Soft wrap",
                    detail: editor.isSoftWrapSuppressed
                        ? "Disabled for an extremely long line" : "Keep long lines visible",
                    symbol: "arrow.turn.down.left",
                    isOn: settingBinding(\.softWrap),
                    isEnabled: !editor.isSoftWrapSuppressed
                )

                rowDivider

                toggleRow(
                    title: "Show invisibles",
                    detail: "Whitespace markers",
                    symbol: "paragraph",
                    isOn: settingBinding(\.showInvisibles)
                )

                rowDivider

                tabWidthMenu

                rowDivider

                fontSizeRow
            }
        }
    }

    private var languageMenu: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon("curlybraces")
            Text(
                editor.activeFile?.languageIsExplicit == false
                    ? "Language · Auto" : "Language"
            )
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            Spacer(minLength: theme.metrics.spacing.sm)
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
                ForEach(languageChoices, id: \.rawValue) { language in
                    Button {
                        editor.setLanguage(language)
                    } label: {
                        HStack {
                            if editor.language == language {
                                Image(systemName: "checkmark")
                            }
                            Text(language.editorDisplayName)
                            if language.hasTreeSitterGrammar {
                                Image(systemName: "circle.fill")
                                    .accessibilityLabel("Bundled syntax grammar")
                            }
                        }
                    }
                }
            } label: {
                menuValue(editor.language.editorDisplayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("text-inspector-language-menu")
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var tabWidthMenu: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon("increase.indent")
            Text("Tab width")
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: theme.metrics.spacing.sm)
            Menu {
                ForEach([2, 4, 8], id: \.self) { width in
                    Button {
                        updateSetting(\.tabWidth, to: width)
                    } label: {
                        if editor.settings.tabWidth == width {
                            Label("\(width) spaces", systemImage: "checkmark")
                        } else {
                            Text("\(width) spaces")
                        }
                    }
                }
            } label: {
                menuValue("\(editor.settings.tabWidth) spaces")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("text-inspector-tab-width-menu")
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var fontSizeRow: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon("textformat.size")
            VStack(alignment: .leading, spacing: 2) {
                Text("Font size")
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text("Editor text")
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: theme.metrics.spacing.sm)
            HStack(spacing: 2) {
                fontSizeButton("minus", delta: -1)
                    .disabled(editor.settings.fontSize <= 10)
                Text("\(Int(editor.settings.fontSize.rounded()))")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 28)
                fontSizeButton("plus", delta: 1)
                    .disabled(editor.settings.fontSize >= 28)
            }
            .fixedSize()
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(minHeight: 50)
    }

    private func fontSizeButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let size = min(max(editor.settings.fontSize + delta, 10), 28)
            updateSetting(\.fontSize, to: size)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 25, height: 25)
        }
        .buttonStyle(ReelIconButtonStyle())
        .accessibilityLabel(delta < 0 ? "Decrease font size" : "Increase font size")
    }

    private func toggleRow(
        title: String,
        detail: String,
        symbol: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: theme.metrics.spacing.sm)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .disabled(!isEnabled)
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(minHeight: 50)
    }

    private func valueRow(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: theme.metrics.spacing.md) {
            settingIcon(symbol)
            Text(title)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.metrics.spacing.md)
            Text(value)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(minHeight: 44)
    }

    private func documentFact(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(theme.type.micro.font)
                .foregroundStyle(theme.palette.textTertiary)
            Text(value)
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuValue(_ value: String) -> some View {
        HStack(spacing: theme.metrics.spacing.sm) {
            Text(value)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .fixedSize()
        .foregroundStyle(theme.palette.textPrimary)
        .contentShape(Rectangle())
    }

    private func settingIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(theme.palette.textTertiary)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textSecondary)
    }

    private func inspectorCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0, content: content)
            .background(theme.palette.surfaceRaised.opacity(0.48))
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                    .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
            }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(height: theme.metrics.hairline)
            .padding(.leading, 40)
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { editor.settings[keyPath: keyPath] },
            set: { updateSetting(keyPath, to: $0) }
        )
    }

    private func updateSetting<Value>(
        _ keyPath: WritableKeyPath<EditorSettings, Value>,
        to value: Value
    ) {
        var settings = editor.settings
        settings[keyPath: keyPath] = value
        editor.updateSettings(settings)
    }

    private var languageChoices: [LanguageID] {
        [.plainText] + LanguageID.treeSitterGrammars
    }
}

extension BibMode {
    fileprivate var inspectorTitle: String {
        switch self {
        case .auto: "Automatic"
        case .biber: "Biber"
        case .bibtex: "BibTeX"
        case .none: "None"
        }
    }
}
