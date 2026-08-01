import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct VideoView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Video",
                subtitle:
                    "Stitch clips, trim, zoom on clicks, and export. Originals are never rewritten."
            )
            WorkspaceDropZone(model: model, workspace: .video)
            HStack(spacing: theme.metrics.spacing.sm) {
                Chip("Trim silence") { selectionNeeded() }
                Chip("Zoom on clicks") { selectionNeeded() }
                Chip("Add captions") { selectionNeeded() }
                Chip("Background padding") { selectionNeeded() }
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

    private func selectionNeeded() {
        // Editor actions arrive in M5; the visible disabled context is intentional in M3.
    }
}
