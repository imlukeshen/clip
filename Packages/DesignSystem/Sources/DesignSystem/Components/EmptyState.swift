import SwiftUI

public struct EmptyState: View {
    @Environment(\.theme) private var theme
    private let headline: String
    private let bodyText: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        headline: String,
        body: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.headline = headline
        self.bodyText = body
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            Text(headline)
                .font(theme.type.body.font)
                .foregroundStyle(theme.palette.textSecondary)
            Text(bodyText)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ReelBorderedButtonStyle())
                    .padding(.top, theme.metrics.spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty state") {
    EmptyState(headline: "Inbox is ready", body: "New captures will appear here.")
        .padding()
        .background(Theme.dark.palette.surfaceBase)
        .environment(\.theme, Theme.dark)
}
