import DesignSystem
import SwiftUI

struct WorkspaceHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(theme.type.title.font)
                .foregroundStyle(theme.palette.textPrimary)
            Text(subtitle)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textTertiary)
                .lineSpacing(3)
        }
        .padding(.bottom, theme.metrics.spacing.xl)
    }
}
