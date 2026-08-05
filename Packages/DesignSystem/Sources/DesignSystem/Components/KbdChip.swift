import SwiftUI

public enum KbdChipState: Sendable {
    case active
    case disabled
    case unknown
}

public struct KbdChip: View {
    @Environment(\.theme) private var theme
    private let text: String
    private let state: KbdChipState

    public init(_ text: String, state: KbdChipState = .active) {
        self.text = text
        self.state = state
    }

    public var body: some View {
        Text(text)
            .font(theme.type.numeric.font)
            .foregroundStyle(
                state == .active ? theme.palette.textSecondary : theme.palette.textTertiary
            )
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(theme.palette.surfaceRaised)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
                    .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
            }
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch state {
        case .active: text
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }
}

#Preview("Keyboard chip states") {
    HStack {
        KbdChip("Active")
        KbdChip("Disabled", state: .disabled)
        KbdChip("Unknown", state: .unknown)
    }
    .padding()
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
