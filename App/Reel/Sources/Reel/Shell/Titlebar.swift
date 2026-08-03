import DesignSystem
import ReelAppCore
import SwiftUI

struct Titlebar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.navigateBack) {
                Image(systemName: "chevron.left").frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!model.canNavigateBack)
            Button(action: model.navigateForward) {
                Image(systemName: "chevron.right").frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!model.canNavigateForward)

            breadcrumb
                .font(theme.type.label.font)

            Spacer()
            if isBrowsing {
                searchField
            }

            Button {
                AppCommandRouter.run("app.commandPalette", in: model)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "command")
                    Text("K")
                }
                .font(theme.type.caption.font)
                .frame(height: 26)
                .padding(.horizontal, 7)
            }
            .buttonStyle(.plain)
            .background(theme.palette.surfacePanel)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help("Command Palette")

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                model.isInspectorVisible ? theme.palette.accent : theme.palette.textTertiary
            )
            .help("Toggle Inspector")
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(theme.palette.surfaceBase)
        .onChange(of: model.searchFocusRequest) { _, _ in
            if isBrowsing { isSearchFocused = true }
        }
    }

    private var isBrowsing: Bool {
        model.editor == nil && model.imageEditor == nil && model.pdfEditor == nil
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(
                    isSearchFocused ? theme.palette.accent : theme.palette.textTertiary
                )
                .accessibilityHidden(true)
            TextField("Search media and folders", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand {
                    if model.isSearching {
                        model.clearSearch()
                    } else {
                        isSearchFocused = false
                    }
                }
            if model.isSearching {
                Button(action: model.clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textTertiary)
                .help("Clear search")
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "command")
                    Text("F")
                }
                .font(theme.type.micro.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .font(theme.type.label.font)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(width: 300)
        .background(theme.palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                .strokeBorder(
                    isSearchFocused ? theme.palette.accentLine : theme.palette.line,
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder private var breadcrumb: some View {
        if model.selectedWorkspace == .inbox {
            HStack(spacing: 5) {
                Button("Media") { model.selectFolder("") }.buttonStyle(.plain)
                if let path = model.selectedFolderPath {
                    let parts = path.split(separator: "/").map(String.init)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.palette.textTertiary)
                        Button(part) {
                            model.selectFolder(parts.prefix(index + 1).joined(separator: "/"))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Recent")
                }
            }
        } else if let editor = model.imageEditor {
            Text("Images  ›  \(editor.sourceURL.lastPathComponent)")
        } else if let editor = model.editor {
            Text("Projects  ›  \(editor.document.name)")
        } else if let editor = model.pdfEditor {
            Text("Documents  ›  \(editor.document.title)")
        } else {
            Text(model.selectedWorkspace.title)
        }
    }
}
