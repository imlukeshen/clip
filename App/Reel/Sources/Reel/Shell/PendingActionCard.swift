import DesignSystem
import ReelAppCore
import SwiftUI

/// Asks before an assistant edit is applied.
///
/// Shared by every workspace that offers the assistant: a chat panel without it
/// stalls on any edit the confirmation policy holds back, with nothing on
/// screen to approve.
struct PendingActionCard: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let action: PendingAssistantAction

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Review \(action.name)").font(theme.type.label.font)
            Text(action.result.message)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
            HStack {
                Button("Apply") { model.approveAssistantAction(action.id) }
                    .buttonStyle(ReelBorderedButtonStyle())
                Button("Skip") { model.rejectAssistantAction(action.id) }
                    .buttonStyle(ReelPlainButtonStyle())
            }
        }
        .padding(9)
        .background(theme.palette.surfaceRaised)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
        )
    }
}
