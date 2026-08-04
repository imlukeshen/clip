import SwiftUI

public enum DropZoneState: Sendable, CaseIterable, Equatable {
    case idle
    case hovered
    case dragTargeted
    case rejecting
}

/// The shared visual treatment for the first control in every workspace.
public struct DropZone: View {
    @Environment(\.theme) private var theme

    private let title: String
    private let detail: String
    private let state: DropZoneState
    private let chooseFiles: () -> Void

    public init(
        title: String,
        detail: String,
        state: DropZoneState = .idle,
        chooseFiles: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.state = state
        self.chooseFiles = chooseFiles
    }

    public var body: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Text(detail)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: theme.metrics.spacing.sm)
            Button("Choose", action: chooseFiles)
                .buttonStyle(ReelBorderedButtonStyle())
                .fixedSize()
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 46)
        .background(
            state == .dragTargeted ? theme.palette.accentDim : theme.palette.surfacePanel
        )
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.dropZone, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.dropZone, style: .continuous)
                .strokeBorder(
                    borderColor,
                    lineWidth: state == .dragTargeted ? 1 : theme.metrics.hairline
                )
        }
        .animation(.easeOut(duration: 0.16), value: state)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var iconName: String {
        state == .rejecting ? "xmark" : "tray.and.arrow.down"
    }

    private var borderColor: Color {
        switch state {
        case .idle: theme.palette.line
        case .hovered: theme.palette.lineStrong
        case .dragTargeted: theme.palette.accent
        case .rejecting: theme.palette.danger
        }
    }

    private var iconColor: Color {
        switch state {
        case .dragTargeted: theme.palette.accent
        case .rejecting: theme.palette.danger
        case .idle, .hovered: theme.palette.textTertiary
        }
    }
}

private struct DropZonePreview: View {
    var body: some View {
        VStack {
            ForEach(DropZoneState.allCases, id: \.self) { state in
                DropZone(title: "Drop files", detail: String(describing: state), state: state) {}
            }
        }
        .padding()
        .background(Theme.dark.palette.surfaceBase)
        .environment(\.theme, Theme.dark)
    }
}

#Preview("Drop zone states") {
    DropZonePreview()
}
