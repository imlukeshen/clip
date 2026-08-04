import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI

struct TextInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.metrics.spacing.sm) {
                Text("Inspector")
                    .font(theme.type.title.font)
                Spacer()
                Label("Text", systemImage: "textformat")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(theme.palette.surfaceRaised)
                    .clipShape(Capsule())
                    .fixedSize()
            }
            .padding(.horizontal, theme.metrics.spacing.lg)
            .frame(height: 48)
            Divider().overlay(theme.palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xxl) {
                    documentSection
                    editorSection
                }
                .padding(theme.metrics.spacing.lg)
            }
            .scrollIndicators(.visible)
        }
        .accessibilityIdentifier("text-inspector")
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

                rowDivider

                languageMenu
            }
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            sectionHeader("Editor", symbol: "slider.horizontal.3")

            inspectorCard {
                toggleRow(
                    title: "Soft wrap",
                    detail: "Keep long lines visible",
                    symbol: "arrow.turn.down.left",
                    isOn: settingBinding(\.softWrap)
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
            Text("Language")
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: theme.metrics.spacing.sm)
            Menu {
                ForEach(languageChoices, id: \.rawValue) { language in
                    Button {
                        editor.setLanguage(language)
                    } label: {
                        if editor.language == language {
                            Label(language.editorDisplayName, systemImage: "checkmark")
                        } else {
                            Text(language.editorDisplayName)
                        }
                    }
                }
            } label: {
                menuValue(editor.language.editorDisplayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityIdentifier("text-language-menu")
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
        }
        .padding(.horizontal, theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityIdentifier("text-tab-width-menu")
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
        isOn: Binding<Bool>
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
