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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
                    .stroke(
                        borderColor,
                        lineWidth: theme.metrics.hairline
                    )
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.965 : 1))
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : 0))
            .shadow(
                color: isHovered && isEnabled && !configuration.isPressed
                    ? .black.opacity(0.12) : .clear,
                radius: configuration.isPressed ? 1 : 5,
                y: configuration.isPressed ? 0 : 1
            )
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: configuration.isPressed)
            .animation(ReelMotion.buttonHover, value: isHovered)
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
