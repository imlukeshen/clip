import DesignSystem
import ReelAppCore
import SwiftUI

struct Titlebar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchHovered = false

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Button(action: model.navigateBack) {
                    Image(systemName: "chevron.left").frame(width: 20, height: 24)
                }
                .buttonStyle(ReelIconButtonStyle())
                .disabled(!model.canNavigateBack)
                Button(action: model.navigateForward) {
                    Image(systemName: "chevron.right").frame(width: 20, height: 24)
                }
                .buttonStyle(ReelIconButtonStyle())
                .disabled(!model.canNavigateForward)

                breadcrumb
                    .font(theme.type.label.font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: isBrowsing ? 260 : .infinity, alignment: .leading)

                Spacer(minLength: isBrowsing ? 350 : 16)

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
                .buttonStyle(ReelPlainButtonStyle())
                .background(theme.palette.surfacePanel)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help("Command Palette")

                Button {
                    model.isInspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(ReelIconButtonStyle(isActive: model.isInspectorVisible))
                .help("Toggle Inspector")
            }

            if isBrowsing {
                searchField
                    .zIndex(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(theme.palette.surfaceBase)
        .onChange(of: model.searchFocusRequest) { _, _ in
            if isBrowsing { isSearchFocused = true }
        }
    }

    private var isBrowsing: Bool {
        model.selectedWorkspace != .convert && model.editor == nil && model.imageEditor == nil
            && model.pdfEditor == nil
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
            Group {
                if model.isSearching {
                    Button(action: model.clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(ReelIconButtonStyle())
                    .help("Clear search")
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "command")
                        Text("F")
                    }
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .frame(width: 22, alignment: .trailing)
        }
        .font(theme.type.label.font)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(width: isSearchFocused ? 326 : 300)
        .background(
            isSearchFocused || isSearchHovered
                ? theme.palette.surfacePanel : theme.palette.surfaceRaised
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                .strokeBorder(
                    isSearchFocused
                        ? theme.palette.accentLine
                        : (isSearchHovered ? theme.palette.lineStrong : theme.palette.line),
                    lineWidth: 1
                )
        }
        .shadow(
            color: isSearchFocused ? theme.palette.accent.opacity(0.1) : .clear,
            radius: 8,
            y: 2
        )
        .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
        .animation(.easeOut(duration: 0.18), value: isSearchHovered)
        .animation(.easeOut(duration: 0.16), value: model.isSearching)
        .onHover { isSearchHovered = $0 }
    }

    @ViewBuilder private var breadcrumb: some View {
        if model.selectedWorkspace == .inbox {
            HStack(spacing: 5) {
                Button("Media") { model.selectFolder("") }.buttonStyle(ReelPlainButtonStyle())
                if let path = model.selectedFolderPath {
                    let parts = path.split(separator: "/").map(String.init)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.palette.textTertiary)
                        Button(part) {
                            model.selectFolder(parts.prefix(index + 1).joined(separator: "/"))
                        }
                        .buttonStyle(ReelPlainButtonStyle())
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Recent")
                }
            }
        } else if model.selectedWorkspace == .photo, let editor = model.imageEditor {
            Text("Images  ›  \(editor.sourceURL.lastPathComponent)")
        } else if model.selectedWorkspace == .video, let editor = model.editor {
            Text("Projects  ›  \(editor.document.name)")
        } else if model.selectedWorkspace == .pdf, let editor = model.pdfEditor {
            Text("Documents  ›  \(editor.document.title)")
        } else {
            Text(model.selectedWorkspace.title)
        }
    }
}
