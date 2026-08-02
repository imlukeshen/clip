import DesignSystem
import ReelAppCore
import SwiftUI

struct Titlebar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                TextField("Search", text: $model.searchQuery)
                    .textFieldStyle(.plain)
            }
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textTertiary)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(width: 190)
            .background(theme.palette.surfacePanel)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))

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

            if model.selectedWorkspace == .inbox {
                Picker("View", selection: $model.browserViewMode) {
                    Image(systemName: "square.grid.2x2").tag(BrowserViewMode.grid)
                    Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 68)
            }

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
        } else if let editor = model.editor {
            Text("Projects  ›  \(editor.document.name)")
        } else {
            Text(model.selectedWorkspace.title)
        }
    }
}
