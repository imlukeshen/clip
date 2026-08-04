import AppKit
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

/// Finder-style "Get Info" for a single asset, shown as a popover anchored to
/// the item it describes.
///
/// This replaces the always-visible metadata pane while browsing: the same
/// preview, name, information list, and quick actions, reached by right-clicking
/// the file rather than living permanently in a column of its own. The editor
/// workspaces keep their dedicated inspectors.
struct AssetInfoPopover: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let asset: AssetRecord

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: theme.metrics.spacing.lg) {
                    AssetPreviewTile(asset: asset, root: model.libraryRoot)
                    heading(title: asset.displayName, subtitle: subtitle(for: asset))
                    if asset.isMissing {
                        Label(
                            "The original file is missing",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.click)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    InspectorFieldList(fields: fields(for: asset))
                }
                .padding(theme.metrics.spacing.lg)
            }
            .scrollIndicators(.automatic)
            quickActions
        }
        .frame(width: 264)
        .frame(maxHeight: 440)
    }

    private func heading(title: String, subtitle: String) -> some View {
        VStack(spacing: 2) {
            // One line, truncated in the middle: Clip's generated names are long
            // enough that wrapping them leaves a ragged orphan, and the full name
            // is spelled out in the Where field below.
            Text(title)
                .font(theme.type.body.font)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Text(subtitle)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }

    private var quickActions: some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.palette.line)
            HStack(spacing: theme.metrics.spacing.sm) {
                action("Quick Look", symbol: "eye") { model.quickLookSelection() }
                action("Reveal", symbol: "folder") { model.revealSelectionInFinder() }
            }
            .font(theme.type.caption.font)
            .lineLimit(1)
            .padding(theme.metrics.spacing.md)
        }
    }

    private func action(
        _ title: String,
        symbol: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ReelBorderedButtonStyle())
        .help(title)
    }

    private func subtitle(for asset: AssetRecord) -> String {
        let format = (asset.container ?? asset.kind.rawValue).uppercased()
        let size = ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file)
        return "\(format) · \(size)"
    }

    /// The format and size live in the subtitle, so they are deliberately absent
    /// here rather than repeated. Kind leads, the way Finder's Get Info does.
    private func fields(for asset: AssetRecord) -> [InspectorField] {
        var fields = [InspectorField(label: "Kind", value: asset.kind.rawValue.capitalized)]
        if let width = asset.width, let height = asset.height {
            fields.append(InspectorField(label: "Dimensions", value: "\(width) × \(height)"))
        }
        if let duration = asset.duration {
            fields.append(InspectorField(label: "Duration", value: durationText(duration.seconds)))
        }
        if let codec = asset.codec, !codec.isEmpty {
            fields.append(InspectorField(label: "Codec", value: codec))
        }
        fields.append(
            InspectorField(
                label: "Created",
                value: asset.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
        )
        // The enclosing folder, not the full path: the file name is already the
        // heading above, so repeating it here cost two wrapped lines and said
        // nothing new.
        let folder = (asset.relativePath as NSString).deletingLastPathComponent
        fields.append(InspectorField(label: "Where", value: folder.isEmpty ? "Library" : folder))
        return fields
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return Duration.seconds(seconds).formatted(
            .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

/// One row of Finder's information list: a right-aligned label and its value.
struct InspectorField: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct InspectorFieldList: View {
    @Environment(\.theme) private var theme
    let fields: [InspectorField]

    /// Wide enough for "Dimensions", the longest label used. A fixed column is
    /// what keeps a long value inside the pane: sized to its content, the grid
    /// grew past the panel edge instead of truncating.
    private let labelWidth = 74.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.md) {
                    Text(field.label)
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Text(field.value)
                        .foregroundStyle(theme.palette.textSecondary)
                        .textSelection(.enabled)
                        .help(field.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(theme.type.caption.font)
        .lineLimit(2)
        .truncationMode(.middle)
    }
}

private struct AssetPreviewTile: View {
    @Environment(\.theme) private var theme
    let asset: AssetRecord
    let root: URL

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(theme.metrics.spacing.sm)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(theme.palette.surfaceRaised)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.card,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.card,
                            style: .continuous
                        )
                        .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
                    }
            } else {
                // No frame to hold: a bordered box around a single glyph reads as
                // a failed image rather than as an icon.
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            }
        }
        .accessibilityHidden(true)
    }

    private var thumbnail: NSImage? {
        guard let path = asset.thumbnailPath else { return nil }
        return NSImage(contentsOf: root.appendingPathComponent(path))
    }

    private var symbol: String {
        switch asset.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .text: "doc.text"
        }
    }
}
