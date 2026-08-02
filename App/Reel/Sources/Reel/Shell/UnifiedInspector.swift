import AppKit
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct UnifiedInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let editor = model.editor {
                EditorInspector(model: model, editor: editor)
            } else {
                libraryInspector
            }
        }
        .frame(width: 280)
        .background(theme.palette.surfacePanel)
    }

    @ViewBuilder private var libraryInspector: some View {
        let selected = model.assets.filter { model.selection.selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Inspector").font(theme.type.label.font)
                Spacer()
                Text("\(selected.count) selected")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Divider().overlay(theme.palette.line)
            if selected.count == 1, let asset = selected.first {
                AssetThumbnailSummary(asset: asset, root: model.libraryRoot)
                Text(asset.displayName)
                    .font(theme.type.body.font)
                    .lineLimit(3)
                LabeledContent("Kind", value: asset.kind.rawValue.capitalized)
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file)
                )
                if let duration = asset.duration {
                    LabeledContent("Duration", value: String(format: "%.2fs", duration.seconds))
                }
                if let width = asset.width, let height = asset.height {
                    LabeledContent("Dimensions", value: "\(width) × \(height)")
                }
                LabeledContent("Modified", value: asset.createdAt.formatted())
                Text(asset.relativePath)
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .textSelection(.enabled)
                Button("Reveal in Finder") { model.revealSelectionInFinder() }
                    .buttonStyle(ReelBorderedButtonStyle())
            } else if selected.count > 1 {
                Text("\(selected.count) files")
                    .font(theme.type.title.font)
                LabeledContent(
                    "Combined size",
                    value: ByteCountFormatter.string(
                        fromByteCount: selected.reduce(0) { $0 + $1.byteSize },
                        countStyle: .file
                    )
                )
                Button("Reveal in Finder") { model.revealSelectionInFinder() }
                    .buttonStyle(ReelBorderedButtonStyle())
            } else {
                EmptyState(
                    headline: "Nothing selected",
                    body: "Select a file to inspect its metadata."
                )
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct AssetThumbnailSummary: View {
    let asset: AssetRecord
    let root: URL

    var body: some View {
        Group {
            if let path = asset.thumbnailPath,
                let image = NSImage(contentsOf: root.appendingPathComponent(path))
            {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 32))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .clipped()
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
