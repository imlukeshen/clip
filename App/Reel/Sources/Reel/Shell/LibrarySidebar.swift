import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct LibrarySidebar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @State private var showsNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Library")
                        .padding(.bottom, 5)
                    smartRow(
                        "All Media",
                        icon: "square.stack.3d.up",
                        count: model.assets.count,
                        selected: model.selectedWorkspace == .inbox
                            && model.selectedFolderPath == nil
                    ) {
                        model.selectFolder(nil)
                    }
                    smartRow(
                        "Videos",
                        icon: "video",
                        count: model.assetCount(for: .video),
                        selected: model.selectedWorkspace == .video
                    ) { model.selectedWorkspace = .video }
                    smartRow(
                        "Photos",
                        icon: "photo",
                        count: model.assetCount(for: .photo),
                        selected: model.selectedWorkspace == .photo
                    ) { model.selectedWorkspace = .photo }
                    smartRow(
                        "PDFs",
                        icon: "doc.richtext",
                        count: model.assetCount(for: .pdf),
                        selected: model.selectedWorkspace == .pdf
                    ) { model.selectedWorkspace = .pdf }

                    HStack {
                        SectionLabel(model.isSearching ? "Matching folders" : "Folders")
                        Spacer()
                        Button {
                            newFolderName = ""
                            showsNewFolder = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .help("New folder")
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 5)

                    if model.isSearching {
                        if model.matchingFolders.isEmpty {
                            Text("No matching folders")
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(model.matchingFolders.prefix(8)) { folder in
                                searchFolderRow(folder)
                            }
                        }
                    } else if let root = model.folderTree {
                        ForEach(root.children ?? []) { node in
                            FolderTreeRow(node: node, model: model, depth: 0)
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)
            smartRow(
                "Convert",
                icon: "arrow.left.arrow.right",
                count: model.assetCount(for: .convert),
                selected: model.selectedWorkspace == .convert
            ) {
                AppCommandRouter.run("navigation.convert", in: model)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider().overlay(theme.palette.line)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.libraryRoot.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Local only")
            }
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textTertiary)
            .padding(12)
        }
        .frame(width: 252)
        .background(theme.palette.surfacePanel)
        .alert("New Folder", isPresented: $showsNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.createFolder(
                    named: newFolderName,
                    in: model.selectedFolderPath ?? ""
                )
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func smartRow(
        _ title: String,
        icon: String,
        count: Int? = nil,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(theme.type.numeric.font)
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selected ? theme.palette.accentDim : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchFolderRow(_ folder: FolderNode) -> some View {
        Button {
            model.selectFolder(folder.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .frame(width: 16)
                    .foregroundStyle(theme.palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name).lineLimit(1)
                    Text(folder.id)
                        .font(theme.type.micro.font)
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if folder.assetCount > 0 {
                    Text("\(folder.assetCount)")
                        .font(theme.type.numeric.font)
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FolderTreeRow: View {
    @Environment(\.theme) private var theme
    let node: FolderNode
    @Bindable var model: AppModel
    let depth: Int
    @State private var showsRename = false
    @State private var renameValue = ""
    @State private var showsNewFolder = false
    @State private var newFolderValue = ""
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if node.children != nil || node.id != "Inbox" {
                    Button {
                        model.toggleFolderExpansion(node.id)
                    } label: {
                        Image(
                            systemName: model.expandedFolders.contains(node.id)
                                ? "chevron.down" : "chevron.right"
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 13, height: 26)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 13, height: 26)
                }
                Button {
                    model.selectFolder(node.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(
                            systemName: node.id == "Inbox"
                                ? "tray"
                                : (model.selectedFolderPath == node.id ? "folder.fill" : "folder")
                        )
                        Text(node.name).lineLimit(1)
                        Spacer()
                        if node.assetCount > 0 {
                            Text("\(node.assetCount)")
                                .font(theme.type.numeric.font)
                                .foregroundStyle(theme.palette.textTertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(
                        model.selectedFolderPath == node.id
                            ? theme.palette.accentDim
                            : (isHovered ? theme.palette.surfaceRaised : Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
            }
            .padding(.leading, CGFloat(depth) * 13)
            .draggable("folder:\(node.id)")
            .dropDestination(for: String.self) { values, _ in
                var accepted = false
                for value in values {
                    if value.hasPrefix("assets:") {
                        let ids = value.dropFirst("assets:".count).split(separator: ",")
                            .map { AssetID(rawValue: String($0)) }
                        model.moveAssets(ids, to: node.id)
                        accepted = true
                    } else if value.hasPrefix("folder:") {
                        model.moveFolder(String(value.dropFirst("folder:".count)), to: node.id)
                        accepted = true
                    }
                }
                return accepted
            }
            .contextMenu {
                Button("New Folder") {
                    newFolderValue = ""
                    showsNewFolder = true
                }
                if node.id != "Inbox" {
                    Button("Rename") {
                        renameValue = node.name
                        showsRename = true
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        model.trashFolder(node.id)
                    }
                }
            }

            if model.expandedFolders.contains(node.id), let children = node.children {
                ForEach(children) { child in
                    FolderTreeRow(node: child, model: model, depth: depth + 1)
                }
            }
        }
        .alert("Rename Folder", isPresented: $showsRename) {
            TextField("Folder name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameFolder(node.id, to: renameValue) }
        }
        .alert("New Folder", isPresented: $showsNewFolder) {
            TextField("Folder name", text: $newFolderValue)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createFolder(named: newFolderValue, in: node.id) }
        }
    }
}
