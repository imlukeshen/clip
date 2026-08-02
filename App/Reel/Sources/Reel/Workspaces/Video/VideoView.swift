import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct VideoView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        if let editor = model.editor {
            EditorView(model: model, editor: editor)
        } else {
            library
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Video",
                subtitle:
                    "Stitch clips, trim, zoom on clicks, and export. Originals are never rewritten."
            )
            WorkspaceDropZone(model: model, workspace: .video)
            HStack(spacing: theme.metrics.spacing.sm) {
                Button("Open editor") {
                    guard let selectedAssetID = model.selectedAssetID else { return }
                    model.openEditor(for: AssetID(rawValue: selectedAssetID))
                }
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(selectedVideo == nil)
                Chip("Trim silence") {}
                    .disabled(true)
                Chip("Zoom on clicks") {}
                    .disabled(true)
                Chip("Add captions") {}
                    .disabled(true)
                Chip("Background padding") {}
                    .disabled(true)
            }
            .padding(.top, 18)
            SectionLabel("Projects")
                .padding(.top, 28)
                .padding(.bottom, 11)
            AssetGrid(
                model: model,
                assets: model.visibleAssets.filter { $0.kind == .video }
            )
        }
    }

    private var selectedVideo: AssetRecord? {
        guard let selectedAssetID = model.selectedAssetID else { return nil }
        return model.assets.first {
            $0.id.rawValue == selectedAssetID && $0.kind == .video
        }
    }
}
