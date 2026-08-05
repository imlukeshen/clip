import SwiftUI

public struct Chip: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(ReelPlainButtonStyle())
            .font(theme.type.caption.font)
            .foregroundStyle(foregroundColor)
            .padding(.vertical, theme.metrics.spacing.xs)
            .padding(.horizontal, 11)
            .background(isHovered ? theme.palette.surfaceRaised : theme.palette.surfacePanel)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return theme.palette.textTertiary }
        return isHovered ? theme.palette.textPrimary : theme.palette.textSecondary
    }
}

#Preview("Chip states") {
    HStack {
        Chip("Default") {}
        Chip("Disabled") {}.disabled(true)
    }
    .padding()
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
