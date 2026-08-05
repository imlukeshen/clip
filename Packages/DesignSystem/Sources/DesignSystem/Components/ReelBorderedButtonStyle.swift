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
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
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
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
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
        isHovered && isEnabled ? theme.palette.lineStrong : theme.palette.line
    }
}
