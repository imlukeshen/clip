import SwiftUI

public enum DropZoneState: Sendable, CaseIterable {
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
        HStack(spacing: theme.metrics.spacing.lg) {
            Image(systemName: iconName)
                .font(theme.type.title.font)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.type.body.font)
                    .foregroundStyle(theme.palette.textSecondary)
                Text(detail)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer()
            Button("Choose files", action: chooseFiles)
                .buttonStyle(ReelBorderedButtonStyle())
        }
        .padding(22)
        .background(state == .dragTargeted ? theme.palette.accentDim : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.dropZone)
                .strokeBorder(
                    borderColor,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var iconName: String {
        state == .rejecting ? "xmark" : "square.and.arrow.down"
    }

    private var borderColor: Color {
        switch state {
        case .idle: theme.palette.lineStrong
        case .hovered: theme.palette.textTertiary
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
