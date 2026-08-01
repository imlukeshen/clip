import SwiftUI

public enum AssetCardState: Sendable {
    case normal
    case selected
    case ingesting(progress: Double)
    case failed(reason: String)
}

public struct AssetCard<Thumbnail: View>: View {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private let title: String
    private let metadata: String
    private let duration: String?
    private let state: AssetCardState
    private let action: () -> Void
    private let retry: (() -> Void)?
    private let thumbnail: Thumbnail

    public init(
        title: String,
        metadata: String,
        duration: String? = nil,
        state: AssetCardState = .normal,
        action: @escaping () -> Void,
        retry: (() -> Void)? = nil,
        @ViewBuilder thumbnail: () -> Thumbnail
    ) {
        self.title = title
        self.metadata = metadata
        self.duration = duration
        self.state = state
        self.action = action
        self.retry = retry
        self.thumbnail = thumbnail()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        thumbnail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let duration {
                            Text(duration)
                                .font(theme.type.numeric.font)
                                .foregroundStyle(theme.palette.textSecondary)
                                .padding(.vertical, 1)
                                .padding(.horizontal, 4)
                                .background(theme.palette.surfaceSunken.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(5)
                        }
                        if case .ingesting(let progress) = state {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(theme.palette.accent)
                        }
                    }
                    .aspectRatio(1.6, contentMode: .fit)
                    .background(theme.palette.surfaceSunken)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                        Text(metadata)
                            .font(theme.type.numeric.font)
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                        if case .failed(let reason) = state {
                            Text(reason)
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.danger)
                                .lineLimit(2)
                        }
                    }
                    .padding(9)
                }
            }
            .buttonStyle(.plain)
            if case .failed = state, let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
            }
        }
        .background(isHovered ? theme.palette.surfaceRaised : theme.palette.surfacePanel)
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card)
                .strokeBorder(borderColor, lineWidth: theme.metrics.hairline)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(metadata)")
    }

    private var borderColor: Color {
        switch state {
        case .selected: theme.palette.accentLine
        case .failed: theme.palette.danger
        case .normal, .ingesting: Color.clear
        }
    }
}

#Preview("Asset card states") {
    HStack {
        AssetCard(title: "Capture", metadata: "MOV · 12 MB", action: {}) {
            Image(systemName: "video").foregroundStyle(Theme.dark.palette.textTertiary)
        }
        AssetCard(title: "Selected", metadata: "PNG · 2 MB", state: .selected, action: {}) {
            Image(systemName: "photo").foregroundStyle(Theme.dark.palette.textTertiary)
        }
        AssetCard(
            title: "Importing",
            metadata: "MOV",
            state: .ingesting(progress: 0.6),
            action: {}
        ) {
            Image(systemName: "video").foregroundStyle(Theme.dark.palette.textTertiary)
        }
    }
    .frame(width: 520)
    .padding()
    .background(Theme.dark.palette.surfaceBase)
    .environment(\.theme, Theme.dark)
}
