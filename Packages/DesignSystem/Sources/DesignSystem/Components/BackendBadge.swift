import SwiftUI

public enum BackendBadgeStyle: Sendable, CaseIterable {
    case remux
    case hardware
    case imageIO
    case ffmpeg
    case unsupported
}

/// Compact disclosure of the local engine selected for a conversion.
public struct BackendBadge: View {
    @Environment(\.theme) private var theme

    private let title: String
    private let style: BackendBadgeStyle

    public init(_ title: String, style: BackendBadgeStyle) {
        self.title = title
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .font(theme.type.numeric.font)
        .foregroundStyle(tint)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.1))
        .clipShape(Capsule())
        .accessibilityLabel("Conversion backend: \(title)")
    }

    private var tint: Color {
        switch style {
        case .remux, .imageIO: theme.palette.success
        case .hardware: theme.palette.accent
        case .ffmpeg: theme.palette.click
        case .unsupported: theme.palette.danger
        }
    }
}

#Preview("Backend badges") {
    VStack(alignment: .leading) {
        BackendBadge("remux · ~2s", style: .remux)
        BackendBadge("VideoToolbox · hardware", style: .hardware)
        BackendBadge("ImageIO · instant", style: .imageIO)
        BackendBadge("FFmpeg · LGPL", style: .ffmpeg)
        BackendBadge("Unavailable", style: .unsupported)
    }
    .padding()
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
