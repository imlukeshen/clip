import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI

struct TextInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Text Inspector")
                .font(theme.type.title.font)
                .padding(.horizontal, theme.metrics.spacing.lg)
                .frame(height: 48)
            Divider().overlay(theme.palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xl) {
                    documentSection
                    editorSection
                }
                .padding(theme.metrics.spacing.lg)
            }
            .scrollIndicators(.visible)
        }
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            SectionLabel("Document")
            LabeledContent("File", value: editor.activeFile?.relativePath ?? "Untitled.txt")
            LabeledContent("Encoding", value: editor.activeFile?.encoding.rawValue ?? "utf8")
            LabeledContent("Line endings", value: editor.activeFile?.lineEnding.rawValue ?? "lf")
            Picker("Language", selection: languageBinding) {
                ForEach(languageChoices, id: \.rawValue) { language in
                    Text(languageTitle(language)).tag(language)
                }
            }
            .pickerStyle(.menu)
            Button("Save now", action: editor.saveNow)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(!editor.isDirty)
        }
        .font(theme.type.caption.font)
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            SectionLabel("Editor")
            Toggle("Soft wrap", isOn: settingBinding(\.softWrap))
            Toggle("Show invisibles", isOn: settingBinding(\.showInvisibles))
            Picker("Tab width", selection: settingBinding(\.tabWidth)) {
                ForEach([2, 4, 8], id: \.self) { width in
                    Text("\(width) spaces").tag(width)
                }
            }
            Stepper(
                "Font size \(editor.settings.fontSize.formatted())",
                value: settingBinding(\.fontSize),
                in: 10...28,
                step: 1
            )
        }
        .font(theme.type.caption.font)
    }

    private var languageBinding: Binding<LanguageID> {
        Binding(
            get: { editor.language },
            set: { language in editor.setLanguage(language) }
        )
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { editor.settings[keyPath: keyPath] },
            set: { value in
                var settings = editor.settings
                settings[keyPath: keyPath] = value
                editor.updateSettings(settings)
            }
        )
    }

    private var languageChoices: [LanguageID] {
        [.plainText] + LanguageID.treeSitterGrammars
    }

    private func languageTitle(_ language: LanguageID) -> String {
        switch language {
        case .plainText: "Plain Text"
        case .cpp: "C++"
        case .css: "CSS"
        case .html: "HTML"
        case .json: "JSON"
        case .sql: "SQL"
        case .xml: "XML"
        case .yaml: "YAML"
        default: language.rawValue.capitalized
        }
    }
}
