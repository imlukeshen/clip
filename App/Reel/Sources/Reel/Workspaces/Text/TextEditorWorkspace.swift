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
        HStack(spacing: theme.metrics.spacing.md) {
            Button(action: model.closeTextEditor) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .help("Back to text library")

            Text(editor.activeFile?.relativePath ?? "Untitled.txt")
                .font(theme.type.label.font)
                .lineLimit(1)
            if editor.isDirty {
                Circle()
                    .fill(theme.palette.textTertiary)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer()
            Text(editor.language.rawValue.uppercased())
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textTertiary)
            Button("Save", action: editor.saveNow)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(!editor.isDirty)
            Button(action: editor.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canUndo)
            .help("Undo")
            Button(action: editor.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canRedo)
            .help("Redo")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 42)
    }

    private var statusBar: some View {
        HStack(spacing: theme.metrics.spacing.lg) {
            Text("Ln \(cursorLine), Col \(cursorColumn)")
            Spacer()
            Text(editor.activeFile?.encoding.displayName ?? "UTF-8")
            Text(editor.activeFile?.lineEnding.displayName ?? "LF")
            Text(editor.settings.softWrap ? "Wrap" : "No wrap")
        }
        .font(theme.type.numeric.font)
        .foregroundStyle(theme.palette.textTertiary)
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 26)
        .background(theme.palette.surfacePanel)
    }
}

extension TextEncoding {
    fileprivate var displayName: String {
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
    fileprivate var displayName: String { rawValue.uppercased() }
}
