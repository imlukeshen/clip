import SwiftUI

public enum StatusItemState: Sendable {
    case ok
    case pending
    case error
}

public struct StatusStrip<Content: View>: View {
    @Environment(\.theme) private var theme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: theme.metrics.spacing.xl) {
            content
        }
        .padding(.vertical, 11)
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surfacePanel)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
        .shadow(color: .black.opacity(0.05), radius: 7, y: 2)
    }
}

public struct StatusItem: View {
    @Environment(\.theme) private var theme
    private let title: String
    private let detail: String?
    private let state: StatusItemState
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        detail: String? = nil,
        state: StatusItemState,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.state = state
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
            if let detail {
                Text(detail)
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ReelPlainButtonStyle())
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var stateColor: Color {
        switch state {
        case .ok: theme.palette.success
        case .pending: theme.palette.click
        case .error: theme.palette.danger
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .ok: "Ready"
        case .pending: "Needs attention"
        case .error: "Error"
        }
    }
}

#Preview("Status item states") {
    StatusStrip {
        StatusItem("Watching", state: .ok)
        StatusItem("Click track", state: .pending, actionTitle: "Grant access") {}
        StatusItem("Library", state: .error)
    }
    .padding()
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
