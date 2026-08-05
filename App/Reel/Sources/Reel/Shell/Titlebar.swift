import AppKit
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
                    .frame(maxWidth: isBrowsing ? 260 : .infinity, alignment: .leading)

                Spacer(minLength: isBrowsing ? 488 : 16)

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
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.control,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.control,
                        style: .continuous
                    )
                    .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
                }
                .help("Command Palette")

                if model.showsEditorInspector {
                    Button {
                        model.isInspectorVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(ReelIconButtonStyle(isActive: model.isInspectorVisible))
                    .help("Toggle Inspector")
                }
            }

            if isBrowsing {
                searchField
                    .zIndex(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(theme.palette.surfaceBase)
        .titlebarDoubleClick()
        .onChange(of: model.searchFocusRequest) { _, _ in
            if isBrowsing { isSearchFocused = true }
        }
    }

    private var isBrowsing: Bool {
        model.selectedWorkspace != .convert && model.editor == nil && model.imageEditor == nil
            && model.pdfEditor == nil && model.textEditor == nil
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isSearchFocused ? theme.palette.accent : theme.palette.textTertiary
                )
                .accessibilityHidden(true)
            TextField("Search", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("library-search-field")
                .focused($isSearchFocused)
                .onExitCommand {
                    if model.isSearching {
                        model.clearSearch()
                    } else {
                        dismissSearchFocus()
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
        .font(theme.type.body.font)
        .padding(.horizontal, 12)
        .frame(width: isSearchFocused ? 464 : 420, height: 34)
        .contentShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
        )
        .onTapGesture {
            isSearchFocused = true
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
                    .fill(theme.palette.surfacePanel)
                OutsideClickMonitor(isActive: isSearchFocused) {
                    dismissSearchFocus()
                }
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
                .strokeBorder(
                    isSearchFocused
                        ? theme.palette.accentLine
                        : (isSearchHovered ? theme.palette.lineStrong : theme.palette.line),
                    lineWidth: isSearchFocused ? 1 : theme.metrics.hairline
                )
        }
        .animation(.easeInOut(duration: 0.18), value: isSearchFocused)
        .animation(.easeOut(duration: 0.16), value: isSearchHovered)
        .animation(.easeOut(duration: 0.16), value: model.isSearching)
        .onHover { isSearchHovered = $0 }
    }

    private func dismissSearchFocus() {
        isSearchFocused = false
        // SwiftUI can immediately restore the field editor during the same
        // mouse event. Resigning on the next main-loop turn makes an outside
        // click reliably dismiss the caret as well as the focus styling.
        Task { @MainActor in
            await Task.yield()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var breadcrumb: some View {
        Breadcrumb(segments: breadcrumbSegments)
    }

    /// The bar is the only thing that says where you are — the workspaces used
    /// to repeat it as a heading a few points below, which read as a stutter.
    private var breadcrumbSegments: [Breadcrumb.Segment] {
        guard !model.isSearching else {
            return locationSegments + [Breadcrumb.Segment(title: "Search")]
        }
        return locationSegments
    }

    private var locationSegments: [Breadcrumb.Segment] {
        if model.selectedWorkspace == .inbox {
            var segments = [Breadcrumb.Segment(title: "Media") { model.selectFolder("") }]
            guard let path = model.selectedFolderPath else {
                return segments + [Breadcrumb.Segment(title: "Recent")]
            }
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                segments.append(
                    Breadcrumb.Segment(title: part) {
                        model.selectFolder(parts.prefix(index + 1).joined(separator: "/"))
                    }
                )
            }
            return segments
        }
        if model.selectedWorkspace == .photo, let editor = model.imageEditor {
            let name =
                model.assets.first(where: { $0.id == editor.document.sourceAssetID })?.displayName
                ?? editor.sourceURL.lastPathComponent
            return [
                Breadcrumb.Segment(title: "Images"),
                Breadcrumb.Segment(
                    title: name,
                    renameAction: { model.renameAsset(editor.document.sourceAssetID, to: $0) }
                ),
            ]
        }
        if model.selectedWorkspace == .video, let editor = model.editor {
            return [
                Breadcrumb.Segment(title: "Projects"),
                Breadcrumb.Segment(
                    title: editor.document.name,
                    renameAction: { _ = editor.renameProject(to: $0) }
                ),
            ]
        }
        if model.selectedWorkspace == .pdf, let editor = model.pdfEditor {
            let name =
                model.assets.first(where: { $0.id == editor.document.sourceAssetID })?.displayName
                ?? editor.sourceURL.lastPathComponent
            return [
                Breadcrumb.Segment(title: "Documents"),
                Breadcrumb.Segment(
                    title: name,
                    renameAction: { model.renameAsset(editor.document.sourceAssetID, to: $0) }
                ),
            ]
        }
        if model.selectedWorkspace == .text, let editor = model.textEditor {
            let name =
                editor.activeFile?.assetID.flatMap { assetID in
                    model.assets.first(where: { $0.id == assetID })?.displayName
                } ?? editor.activeFile?.relativePath ?? "Untitled"
            return [
                Breadcrumb.Segment(title: "Text"),
                Breadcrumb.Segment(
                    title: name,
                    renameAction: model.renameOpenTextFile
                ),
            ]
        }
        return [Breadcrumb.Segment(title: model.selectedWorkspace.title)]
    }
}
