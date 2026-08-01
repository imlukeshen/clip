import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct PhotoView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Photo",
                subtitle:
                    "Annotate, crop, and redact. Redaction flattens pixels rather than drawing over them."
            )
            WorkspaceDropZone(model: model, workspace: .photo)
            HStack(spacing: theme.metrics.spacing.sm) {
                Chip("Annotate") {}
                Chip("Crop") {}
                Chip("Redact") {}
                Chip("Alt text") {}
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
}
