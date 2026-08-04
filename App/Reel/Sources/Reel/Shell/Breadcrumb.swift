import DesignSystem
import SwiftUI

/// The location shown at the top left of the window.
///
/// Only the last segment is drawn at full strength, so the eye lands on where
/// you are rather than on how you got there. Ancestors stay quiet until you
/// hover one, which is also the affordance that they are clickable.
struct Breadcrumb: View {
    struct Segment {
        let title: String
        var action: (() -> Void)?
    }

    @Environment(\.theme) private var theme
    let segments: [Segment]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                        .padding(.horizontal, 1)
                        .accessibilityHidden(true)
                }
                if index == segments.count - 1 {
                    Text(segment.title)
                        .font(theme.type.label.font.weight(.medium))
                        .foregroundStyle(theme.palette.textPrimary)
                } else if let action = segment.action {
                    Button(segment.title, action: action)
                        .buttonStyle(BreadcrumbSegmentStyle())
                } else {
                    Text(segment.title)
                        .font(theme.type.label.font)
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(segments.map(\.title).joined(separator: ", "))
    }
}

private struct BreadcrumbSegmentStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.type.label.font)
            .foregroundStyle(
                isHovered ? theme.palette.textPrimary : theme.palette.textSecondary
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(isHovered ? theme.palette.accentDim : .clear)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.small, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
