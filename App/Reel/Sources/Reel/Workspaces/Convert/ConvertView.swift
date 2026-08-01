import DesignSystem
import ReelAppCore
import SwiftUI

struct ConvertView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Convert",
                subtitle:
                    "Pick a target format and see which local engine will run before committing."
            )
            WorkspaceDropZone(model: model, workspace: .convert)
            SectionLabel("Queue")
                .padding(.top, 28)
                .padding(.bottom, 11)
            EmptyState(
                headline: "Queue is empty",
                body: "Drop files above. Conversion backends arrive in M4."
            )
        }
    }
}
