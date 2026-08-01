import SwiftUI

public struct ReelBorderedButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.vertical, theme.metrics.spacing.xs)
            .padding(.horizontal, 11)
            .background(configuration.isPressed ? theme.palette.surfaceRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                    .stroke(theme.palette.lineStrong, lineWidth: theme.metrics.hairline)
            }
    }
}
