import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI

struct TextEditorWorkspace: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: TextEditorViewModel
    @State private var cursorLine = 1
    @State private var cursorColumn = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.palette.line)
                CodeEditor(
                    text: $editor.text,
                    language: editor.language,
                    settings: editor.settings,
                    undoManager: editor.undoManager,
                    onSave: editor.saveNow
                ) { line, column in
                    cursorLine = line
                    cursorColumn = column
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

            Label(editor.language.editorDisplayName, systemImage: "textformat")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(theme.palette.surfaceRaised)
                .clipShape(Capsule())

            Spacer()

            saveControl

            Button(action: editor.undo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(!editor.undoManager.canUndo)
            .help("Undo")

            Button(action: editor.redo) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(!editor.undoManager.canRedo)
            .help("Redo")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 48)
        .background(theme.palette.surfacePanel)
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
