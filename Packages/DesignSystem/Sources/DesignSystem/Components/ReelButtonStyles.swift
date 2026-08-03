import SwiftUI

public struct ReelPlainButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ReelPlainButtonBody(configuration: configuration)
    }
}

private struct ReelPlainButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .brightness(isEnabled && isHovered ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { isHovered = $0 }
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
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.34)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .shadow(
                color: isHovered && isEnabled ? .black.opacity(0.12) : .clear,
                radius: 3,
                y: 1
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .animation(.easeOut(duration: 0.18), value: isActive)
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
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let theme: Theme

    var body: some View {
        configuration.label
            .font(theme.type.label.font)
            .foregroundStyle(.white)
            .padding(.vertical, theme.metrics.spacing.sm)
            .padding(.horizontal, theme.metrics.spacing.lg)
            .background(theme.palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
            .brightness(isHovered && isEnabled ? 0.07 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.36)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .shadow(
                color: isHovered && isEnabled ? theme.palette.accent.opacity(0.22) : .clear,
                radius: 7,
                y: 2
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
