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
    @State private var isFlashing = false
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
            .scaleEffect(pressScale)
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: isFlashing)
            .animation(ReelMotion.buttonHover, value: isHovered)
            .buttonPressFlash(isPressed: configuration.isPressed, isFlashing: $isFlashing)
            .onHover { isHovered = $0 }
    }

    /// Dips under the pointer, then springs briefly past rest on release so a
    /// quick click stays visible after the button is let go.
    private var pressScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if configuration.isPressed { return 0.94 }
        return isFlashing ? 1.04 : 1
    }

    private var backgroundColor: Color {
        if configuration.isPressed || isFlashing { return theme.palette.accentLine }
        if isHovered && isEnabled { return theme.palette.surfaceRaised }
        return .clear
    }

    private var borderColor: Color {
        if configuration.isPressed || isFlashing { return theme.palette.accentLine }
        return isHovered && isEnabled ? theme.palette.lineStrong : theme.palette.line
    }
}
