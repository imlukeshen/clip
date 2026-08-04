import SwiftUI

public enum ReelMotion {
    public static var buttonPress: Animation {
        .snappy(duration: 0.24, extraBounce: 0.14)
    }

    public static var buttonHover: Animation {
        .smooth(duration: 0.18)
    }
}

public struct ReelPlainButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ReelPlainButtonBody(configuration: configuration)
    }
}

private struct ReelPlainButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(opacity)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: configuration.isPressed)
            .animation(ReelMotion.buttonHover, value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var opacity: Double {
        guard isEnabled else { return 0.36 }
        if configuration.isPressed { return 0.7 }
        return isHovered ? 0.82 : 1
    }
}

public struct ReelIconButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    private let isActive: Bool

    public init(isActive: Bool = false) {
        self.isActive = isActive
    }

    public func makeBody(configuration: Configuration) -> some View {
        ReelIconButtonBody(
            configuration: configuration,
            theme: theme,
            isActive: isActive
        )
    }
}

private struct ReelIconButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let theme: Theme
    let isActive: Bool

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .foregroundStyle(
                isActive ? theme.palette.accent : theme.palette.textSecondary
            )
            .background(backgroundColor)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.34)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.93 : 1))
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: configuration.isPressed)
            .animation(ReelMotion.buttonHover, value: isHovered)
            .animation(ReelMotion.buttonHover, value: isActive)
            .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed { return theme.palette.accentDim }
        if isActive { return theme.palette.accentDim }
        if isHovered && isEnabled { return theme.palette.surfaceRaised }
        return .clear
    }
}

public struct ReelProminentButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ReelProminentButtonBody(configuration: configuration, theme: theme)
    }
}

private struct ReelProminentButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let theme: Theme

    var body: some View {
        configuration.label
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.accentOn)
            .padding(.vertical, theme.metrics.spacing.sm)
            .padding(.horizontal, theme.metrics.spacing.lg)
            .background(theme.palette.accent)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
            .opacity(prominenceOpacity)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : ReelMotion.buttonPress, value: configuration.isPressed)
            .animation(ReelMotion.buttonHover, value: isHovered)
            .onHover { isHovered = $0 }
    }

    /// A solid neutral fill cannot brighten on hover, so the feedback comes
    /// from the fill easing back instead.
    private var prominenceOpacity: Double {
        guard isEnabled else { return 0.36 }
        if configuration.isPressed { return 0.78 }
        return isHovered ? 0.88 : 1
    }
}
