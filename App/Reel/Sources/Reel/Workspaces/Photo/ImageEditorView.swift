import AppKit
import CoreModel
import DesignSystem
import MediaEngine
import ReelAppCore
import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: ImageEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider().overlay(theme.palette.line)
            HStack(spacing: 0) {
                toolRail
                Divider().overlay(theme.palette.line)
                ImageCanvasView(editor: editor)
            }
        }
        .background(theme.palette.surfaceBase)
        .overlay(alignment: .bottom) {
            if let notice = editor.notice {
                Toast(notice)
                    .padding(.bottom, 18)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.1))
                        editor.clearNotice()
                    }
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button {
                model.closeImageEditor()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Close Image Editor")

            VStack(alignment: .leading, spacing: 2) {
                Text(editor.sourceURL.deletingPathExtension().lastPathComponent)
                    .font(theme.type.label.font)
                Text(editor.isRendering ? "Updating preview…" : "Saved locally")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer()
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!editor.undoManager.canUndo)
            .help("Undo")
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!editor.undoManager.canRedo)
            .help("Redo")
            Button("Export…", action: export)
                .buttonStyle(ReelBorderedButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(theme.palette.surfacePanel)
    }

    private var toolRail: some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(ImageEditorTool.allCases) { tool in
                    Button {
                        editor.activate(tool)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 15, weight: .medium))
                            Text(tool.title)
                                .font(.system(size: 8.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(width: 50, height: 43)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        editor.activeTool == tool
                            ? theme.palette.accent : theme.palette.textSecondary
                    )
                    .background(
                        editor.activeTool == tool
                            ? theme.palette.accentDim : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(tool.title)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 5)
        }
        .frame(width: 62)
        .background(theme.palette.surfacePanel)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.nameFieldStringValue =
            editor.sourceURL.deletingPathExtension().lastPathComponent + "-edited.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format: ImageExportFormat
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": format = .jpeg(quality: 0.92)
            case "heic", "heif": format = .heic(quality: 0.92)
            default: format = .png
            }
            editor.export(to: url, format: format)
        }
    }
}

private struct ImageCanvasView: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: ImageEditorViewModel
    @State private var gestureStart: CGPoint?
    @State private var gestureCurrent: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.22)
                if let rendered = editor.renderedImage {
                    let rect = fittedRect(
                        imageSize: CGSize(width: rendered.width, height: rendered.height),
                        in: proxy.size
                    )
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .overlay(alignment: .topLeading) {
                            if let draft = draftRect(in: rect) {
                                Rectangle()
                                    .fill(theme.palette.accentDim)
                                    .stroke(
                                        theme.palette.accent,
                                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                    )
                                    .frame(width: draft.width, height: draft.height)
                                    .offset(x: draft.minX - rect.minX, y: draft.minY - rect.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                    if editor.isRendering {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ProgressView("Rendering image…")
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(in: proxy.size))
        }
    }

    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard drawsLayer else { return }
                if gestureStart == nil { gestureStart = value.startLocation }
                gestureCurrent = value.location
            }
            .onEnded { value in
                defer {
                    gestureStart = nil
                    gestureCurrent = nil
                }
                guard drawsLayer, let rendered = editor.renderedImage else { return }
                let rect = fittedRect(
                    imageSize: CGSize(width: rendered.width, height: rendered.height),
                    in: size
                )
                let start = normalized(value.startLocation, in: rect)
                let end = normalized(value.location, in: rect)
                editor.commitGesture(from: start, to: end)
            }
    }

    private var drawsLayer: Bool {
        ![.select, .crop, .padding, .eyedropper].contains(editor.activeTool)
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height) * 0.9
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    private func draftRect(in imageRect: CGRect) -> CGRect? {
        guard let start = gestureStart, let current = gestureCurrent else { return nil }
        let clippedStart = CGPoint(
            x: min(max(start.x, imageRect.minX), imageRect.maxX),
            y: min(max(start.y, imageRect.minY), imageRect.maxY)
        )
        let clippedCurrent = CGPoint(
            x: min(max(current.x, imageRect.minX), imageRect.maxX),
            y: min(max(current.y, imageRect.minY), imageRect.maxY)
        )
        return CGRect(
            x: min(clippedStart.x, clippedCurrent.x),
            y: min(clippedStart.y, clippedCurrent.y),
            width: abs(clippedCurrent.x - clippedStart.x),
            height: abs(clippedCurrent.y - clippedStart.y)
        )
    }
}
