import DesignSystem
import ReelAppCore
import SwiftUI

struct WorkspaceTabs: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Workspace.allCases) { workspace in
                DesignSystem.WorkspaceTab(
                    workspace.title,
                    systemImage: workspace.systemImage,
                    badge: badge(for: workspace),
                    isActive: model.selectedWorkspace == workspace
                ) {
                    model.selectedWorkspace = workspace
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .background(theme.palette.surfaceBase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces")
    }

    private func badge(for workspace: Workspace) -> String {
        return String(model.assetCount(for: workspace))
    }
}
