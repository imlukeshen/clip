import CoreModel
import DesignSystem
import ReelAppCore
import SwiftUI

struct TeXProjectSidebar: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project")
                    .font(theme.type.label.font)
                Spacer()
                Menu {
                    ForEach(mainFileChoices) { file in
                        Button {
                            editor.setMainFile(file.id)
                        } label: {
                            if file.id == editor.document.mainFileID {
                                Label(file.relativePath, systemImage: "checkmark")
                            } else {
                                Text(file.relativePath)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "target")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Choose the main LaTeX file")
                .accessibilityLabel("Choose main LaTeX file")
            }
            .padding(.horizontal, theme.metrics.spacing.md)
            .frame(height: 40)

            Divider().overlay(theme.palette.line)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(editor.document.files) { file in
                        Button {
                            editor.selectFile(file.id)
                        } label: {
                            fileRow(file)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if isMainFileChoice(file) {
                                Button("Set as Main File") { editor.setMainFile(file.id) }
                            }
                        }
                    }
                }
                .padding(6)
            }

            if let analysis = editor.texProjectAnalysis,
                !analysis.missingDependencies.isEmpty
            {
                Divider().overlay(theme.palette.line)
                Label(
                    "\(analysis.missingDependencies.count) missing",
                    systemImage: "exclamationmark.triangle"
                )
                .font(theme.type.micro.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, theme.metrics.spacing.md)
                .frame(height: 34)
                .help(analysis.missingDependencies.sorted().joined(separator: "\n"))
            }
        }
        .background(theme.palette.surfacePanel)
        .accessibilityIdentifier("latex-project-sidebar")
    }

    private func fileRow(_ file: TextFile) -> some View {
        let selected = file.id == editor.activeFileID
        let reachable = editor.isReachableFromMain(file)
        return HStack(spacing: theme.metrics.spacing.sm) {
            Color.clear.frame(width: CGFloat(pathDepth(file.relativePath)) * 10)
            Image(systemName: file.relativePath.hasSuffix(".bib") ? "books.vertical" : "doc.text")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(
                    reachable ? theme.palette.textSecondary : theme.palette.textTertiary
                )
                .frame(width: 15)
            Text(URL(fileURLWithPath: file.relativePath).lastPathComponent)
                .font(theme.type.caption.font)
                .foregroundStyle(reachable ? theme.palette.textPrimary : theme.palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if file.id == editor.document.mainFileID {
                Image(systemName: "target")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .help("Main file")
            } else if !reachable, isMainFileChoice(file) {
                Circle()
                    .stroke(theme.palette.textTertiary, lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .help("Not reachable from the main file")
            }
        }
        .padding(.horizontal, theme.metrics.spacing.sm)
        .frame(height: 30)
        .background(
            selected ? theme.palette.accentDim : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var mainFileChoices: [TextFile] {
        editor.document.files.filter(isMainFileChoice)
    }

    private func isMainFileChoice(_ file: TextFile) -> Bool {
        ["tex", "latex"].contains(
            URL(fileURLWithPath: file.relativePath).pathExtension.lowercased()
        )
    }

    private func pathDepth(_ path: String) -> Int {
        max(path.split(separator: "/").count - 1, 0)
    }
}
