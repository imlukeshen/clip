import SwiftUI

public struct Toast: View {
    @Environment(\.theme) private var theme
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Text(message)
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, theme.metrics.spacing.lg)
            .background(theme.palette.surfaceRaised)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                    .stroke(theme.palette.lineStrong, lineWidth: theme.metrics.hairline)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .accessibilityAddTraits(.isStaticText)
    }
}
