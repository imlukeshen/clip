import SwiftUI

public struct WorkspaceTab: View {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private let title: String
    private let systemImage: String
    private let badge: String?
    private let isActive: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String,
        badge: String? = nil,
        isActive: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                Text(title)
                if let badge {
                    Text(badge)
                        .font(theme.type.numeric.font)
                        .foregroundStyle(
                            isActive ? theme.palette.accent : theme.palette.textTertiary
                        )
                        .padding(.vertical, 1)
                        .padding(.horizontal, 6)
                        .background(
                            isActive ? theme.palette.accentDim : theme.palette.surfacePanel
                        )
                        .clipShape(Capsule())
                }
            }
            .font(theme.type.label.font)
            .foregroundStyle(
                isActive || isHovered ? theme.palette.textPrimary : theme.palette.textTertiary
            )
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? theme.palette.accent : Color.clear)
                    .frame(height: 1.5)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("workspace-tab-\(title.lowercased())")
        .accessibilityValue(isActive ? "selected" : "unselected")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview("Workspace tab states") {
    HStack(spacing: 0) {
        WorkspaceTab("Inbox", systemImage: "tray", badge: "3", isActive: true) {}
        WorkspaceTab("Photo", systemImage: "photo", badge: "0", isActive: false) {}
    }
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
