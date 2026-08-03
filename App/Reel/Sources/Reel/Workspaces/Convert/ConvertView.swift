import ConvertKit
import DesignSystem
import ReelAppCore
import SwiftUI

struct ConvertView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "Convert",
                subtitle:
                    "Pick a target format and see which local engine will run before committing."
            )
            WorkspaceDropZone(model: model, workspace: .convert)
            HStack {
                SectionLabel("Queue")
                Spacer()
                if !model.conversionQueue.isEmpty {
                    Text(
                        "\(model.conversionQueue.count) file\(model.conversionQueue.count == 1 ? "" : "s")"
                    )
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 11)

            if model.conversionQueue.isEmpty {
                EmptyState(
                    headline: "Queue is empty",
                    body: "Drop video, images, or audio above to choose an output format."
                )
            } else {
                ConversionQueue(model: model)
                HStack {
                    Text("Outputs are saved to Reel/Exports")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                    Spacer()
                    Button(model.isConverting ? "Converting…" : "Convert") {
                        model.convertQueuedItems()
                    }
                    .buttonStyle(ReelProminentButtonStyle())
                    .tint(theme.palette.accent)
                    .disabled(model.isConverting || !model.hasConvertibleItems)
                }
                .padding(.top, theme.metrics.spacing.lg)
            }
        }
    }
}

private struct ConversionQueue: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.conversionQueue.enumerated()), id: \.element.id) { index, item in
                ConversionQueueRow(model: model, item: item)
                if index < model.conversionQueue.count - 1 {
                    Rectangle()
                        .fill(theme.palette.line)
                        .frame(height: theme.metrics.hairline)
                        .padding(.horizontal, theme.metrics.spacing.lg)
                }
            }
        }
        .background(theme.palette.surfacePanel)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .stroke(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
    }
}

private struct ConversionQueueRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let item: ConversionQueueItem

    var body: some View {
        HStack(spacing: theme.metrics.spacing.lg) {
            Image(systemName: iconName)
                .frame(width: 24)
                .foregroundStyle(theme.palette.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.asset.displayName)
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(item.sourceDescription)
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .accessibilityHidden(true)

            Picker(
                "Target format",
                selection: Binding(
                    get: { item.target },
                    set: { model.selectConversionTarget($0, for: item.id) }
                )
            ) {
                ForEach(item.availableTargets) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150, alignment: .leading)
            .disabled(isConverting)

            BackendBadge(backendTitle, style: backendStyle)
                .frame(width: 150, alignment: .leading)

            status
                .frame(width: 92, alignment: .trailing)

            Button {
                model.removeConversion(item.id)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(ReelPlainButtonStyle())
            .foregroundStyle(theme.palette.textTertiary)
            .disabled(isConverting)
            .accessibilityLabel("Remove \(item.asset.displayName)")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            Text("Ready")
                .foregroundStyle(theme.palette.textTertiary)
        case .converting:
            HStack(spacing: 6) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(theme.palette.accent)
                    .frame(width: 50)
                Text(item.progress.formatted(.percent.precision(.fractionLength(0))))
            }
            .foregroundStyle(theme.palette.textSecondary)
        case .completed:
            Label("Done", systemImage: "checkmark")
                .foregroundStyle(theme.palette.success)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(theme.palette.danger)
                .help(failureReason ?? "Conversion failed")
        }
    }

    private var isConverting: Bool {
        if case .converting = item.status { return true }
        return false
    }

    private var failureReason: String? {
        if case .failed(let reason) = item.status { return reason }
        return nil
    }

    private var iconName: String {
        switch item.asset.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
        }
    }

    private var backendTitle: String {
        switch item.plan.backend {
        case .remux: "remux · ~2s"
        case .videoToolbox: "VideoToolbox · hardware"
        case .imageIO: "ImageIO · instant"
        case .ffmpeg: "FFmpeg · LGPL"
        case .unsupported: "Unavailable"
        }
    }

    private var backendStyle: BackendBadgeStyle {
        switch item.plan.backend {
        case .remux: .remux
        case .videoToolbox: .hardware
        case .imageIO: .imageIO
        case .ffmpeg: .ffmpeg
        case .unsupported: .unsupported
        }
    }
}
