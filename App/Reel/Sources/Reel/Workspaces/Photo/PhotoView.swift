import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct PhotoView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        if let editor = model.imageEditor {
            ImageEditorView(model: model, editor: editor)
        } else {
            library
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Photo",
                subtitle:
                    "Annotate, crop, and redact. Redaction flattens pixels rather than drawing over them."
            )
            WorkspaceDropZone(model: model, workspace: .photo)
            HStack(spacing: theme.metrics.spacing.sm) {
                Button("Open editor") { open(.select) }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(selectedImage == nil)
                Chip("Annotate") { open(.arrow) }
                    .disabled(selectedImage == nil)
                Chip("Crop") { open(.crop) }
                    .disabled(selectedImage == nil)
                Chip("Redact") { open(.redact) }
                    .disabled(selectedImage == nil)
                Chip("Padding") { open(.padding) }
                    .disabled(selectedImage == nil)
            }
            .padding(.top, 18)
            SectionLabel("Images")
                .padding(.top, 28)
                .padding(.bottom, 11)
            AssetGrid(
                model: model,
                assets: model.visibleAssets.filter { $0.kind == .image }
            )
        }
    }

    private var selectedImage: AssetRecord? {
        guard let selectedAssetID = model.selectedAssetID else { return nil }
        return model.assets.first {
            $0.id.rawValue == selectedAssetID && $0.kind == .image
        }
    }

    private func open(_ tool: ImageEditorTool) {
        guard let selectedImage else { return }
        model.openImageEditor(for: selectedImage.id, initialTool: tool)
    }
}
