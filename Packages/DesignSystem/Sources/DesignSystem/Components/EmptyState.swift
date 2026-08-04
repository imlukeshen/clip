import SwiftUI

public struct EmptyState: View {
    @Environment(\.theme) private var theme
    private let headline: String
    private let bodyText: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        headline: String,
        body: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.headline = headline
        self.bodyText = body
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: theme.metrics.spacing.sm) {
            Text(headline)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textTertiary)
                .multilineTextAlignment(.center)
            if let bodyText {
                Text(bodyText)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ReelBorderedButtonStyle())
                    .padding(.top, theme.metrics.spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, theme.metrics.spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty state") {
    EmptyState(headline: "No captures yet")
        .padding()
        .background(Theme.dark.palette.surfaceBase)
        .environment(\.theme, Theme.dark)
}
