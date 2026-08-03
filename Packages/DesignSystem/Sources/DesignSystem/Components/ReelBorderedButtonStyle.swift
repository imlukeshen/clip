import SwiftUI

public struct ReelBorderedButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ReelBorderedButtonBody(configuration: configuration, theme: theme)
    }
}

private struct ReelBorderedButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let theme: Theme

    var body: some View {
        configuration.label
            .font(theme.type.label.font)
            .foregroundStyle(
                isHovered && isEnabled ? theme.palette.textPrimary : theme.palette.textSecondary
            )
            .padding(.vertical, theme.metrics.spacing.xs)
            .padding(.horizontal, 11)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                    .stroke(
                        borderColor,
                        lineWidth: theme.metrics.hairline
                    )
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .shadow(
                color: isHovered && isEnabled ? .black.opacity(0.12) : .clear,
                radius: 5,
                y: 1
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed { return theme.palette.accentDim }
        if isHovered && isEnabled { return theme.palette.surfaceRaised }
        return .clear
    }

    private var borderColor: Color {
        isHovered && isEnabled ? theme.palette.accentLine : theme.palette.lineStrong
    }
}
