import AppKit
import CaptureKit
import DesignSystem
import ReelAppCore
import SwiftUI

/// Recent screenshots and recordings, ready to paste.
///
/// This is the surface that replaced filing every capture into the library.
/// Entries expire on their own, so the useful actions are the ones that get a
/// capture out of here: copy it, or keep it.
struct CaptureHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    /// How to close the surface after a copy. The sheet leans on the SwiftUI
    /// `dismiss` action; the floating panel passes its own dismissal so a pick
    /// closes the panel and hands focus back to the app the user was in.
    var onClose: (() -> Void)?

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.line)
            if model.captureHistory.isEmpty {
                EmptyState(headline: "No recent captures")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(width: 480, height: 460)
        .background {
            ZStack {
                theme.palette.surfaceBase
                OutsideClickMonitor(isActive: model.isCaptureHistoryPresented) {
                    model.isCaptureHistoryPresented = false
                }
            }
        }
        .task { await model.refreshCaptureHistory() }
    }

    private var header: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Text("Capture History")
                .font(theme.type.title.font)
            Spacer()
            if !model.captureHistory.isEmpty {
                Button("Clear", role: .destructive) { model.clearCaptureHistory() }
                    .buttonStyle(ReelBorderedButtonStyle())
            }
            HStack(spacing: 2) {
                Image(systemName: "command")
                Image(systemName: "shift")
                Text("C")
            }
            .font(theme.type.numeric.font)
            .foregroundStyle(theme.palette.textTertiary)
        }
        .padding(theme.metrics.spacing.lg)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.captureHistory) { item in
                    CaptureHistoryRow(
                        item: item,
                        url: model.captureHistoryURL(for: item),
                        copy: {
                            model.copyCaptureToPasteboard(item)
                            close()
                        },
                        save: { model.saveCaptureToLibrary(item) },
                        delete: { model.removeCapture(item) }
                    )
                }
            }
            .padding(theme.metrics.spacing.sm)
        }
    }
}

/// One capture. The row itself copies, because that is what you came for; the
/// rarer actions wait until you hover.
private struct CaptureHistoryRow: View {
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    let item: CaptureHistoryItem
    let url: URL?
    let copy: () -> Void
    let save: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: copy) {
            HStack(spacing: theme.metrics.spacing.md) {
                CaptureThumbnail(url: url, kind: item.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(theme.type.body.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                }
                Spacer(minLength: theme.metrics.spacing.sm)
                if isHovering {
                    actions
                }
            }
            .padding(.horizontal, theme.metrics.spacing.md)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReelPlainButtonStyle())
        .onHover { isHovering = $0 }
        .help("Copy \(item.displayName)")
    }

    private var actions: some View {
        HStack(spacing: theme.metrics.spacing.xs) {
            // Only media becomes a library asset; a text or file-set entry has
            // no file the library would want, so saving it is hidden.
            if item.canSaveToLibrary {
                action("tray.and.arrow.down", "Save to library", save)
            }
            action("trash", "Remove from history", delete)
        }
    }

    private func action(
        _ symbol: String,
        _ label: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(theme.type.label.font)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReelPlainButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private var subtitle: String {
        // Text and file-set entries speak for themselves through their preview;
        // a byte count would say nothing useful next to a line of copied text.
        if let preview = item.preview, !preview.isEmpty {
            return "\(relativeAge) · \(preview)"
        }
        let size = ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
        return "\(relativeAge) · \(size)"
    }

    private var relativeAge: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.capturedAt, relativeTo: Date())
    }
}

/// A still for images, a glyph for recordings.
///
/// Pulling a frame out of a video would mean an `AVAssetImageGenerator` pass per
/// row on a panel that opens on a keystroke; the film icon reads clearly enough
/// next to the file name.
private struct CaptureThumbnail: View {
    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    let url: URL?
    let kind: CaptureHistoryItem.Kind

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: Self.glyph(for: kind))
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(width: 52, height: 36)
        .background(theme.palette.surfaceRaised)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.small, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.small, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard kind == .image, let url else { return }
        let loaded = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        image = loaded
    }

    /// The glyph that stands in for an entry with no thumbnail of its own.
    private static func glyph(for kind: CaptureHistoryItem.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .text: "text.alignleft"
        case .fileList: "doc.on.doc"
        }
    }
}
