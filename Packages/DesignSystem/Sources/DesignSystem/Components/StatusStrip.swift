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
        HStack(spacing: theme.metrics.spacing.lg) {
            content
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surfacePanel)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
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
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ReelPlainButtonStyle())
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.accent)
                    .fixedSize()
            }
        }
        .lineLimit(1)
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
