import SwiftUI

/// Menu styling that matches the icon and bordered buttons beside it.
///
/// A menu sits in the same toolbars as the buttons and should not read as a
/// different kind of control. SwiftUI's `MenuStyle` exposes no pressed state,
/// so a menu cannot carry the press-and-release animation the button styles
/// use; hover, shape and colour are matched instead, and opening the menu is
/// itself the acknowledgement that the click landed.
public struct ReelMenuStyle: MenuStyle {
    private let isProminent: Bool

    public init(isProminent: Bool = false) {
        self.isProminent = isProminent
    }

    public func makeBody(configuration: Configuration) -> some View {
        ReelMenuBody(configuration: configuration, isProminent: isProminent)
    }
}

private struct ReelMenuBody: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    let configuration: MenuStyleConfiguration
    let isProminent: Bool

    var body: some View {
        Menu(configuration)
            .menuIndicator(.hidden)
            .font(theme.type.label.font)
            .foregroundStyle(foreground)
            .padding(.vertical, isProminent ? theme.metrics.spacing.xs : 0)
            .padding(.horizontal, isProminent ? theme.metrics.spacing.sm : 0)
            .background(background)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.38)
            .animation(ReelMotion.buttonHover, value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        guard isEnabled else { return theme.palette.textTertiary }
        return isHovered ? theme.palette.textPrimary : theme.palette.textSecondary
    }

    private var background: Color {
        isHovered && isEnabled ? theme.palette.surfaceRaised : .clear
    }
}
