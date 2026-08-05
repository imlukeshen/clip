import AppKit
import CoreModel
import DesignSystem
import MediaEngine
import ReelAppCore
import SearchEngine
import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: ImageEditorViewModel
    @State private var zoomLevel = 1.0
    @State private var liveTextSpans: [OCRSpan] = []

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider().overlay(theme.palette.line)
            toolOptionsBar
            Divider().overlay(theme.palette.line)
            HStack(spacing: 0) {
                toolRail
                Divider().overlay(theme.palette.line)
                ImageCanvasView(
                    editor: editor,
                    zoomLevel: $zoomLevel,
                    liveTextSpans: liveTextSpans,
                    onSearch: model.searchLibrary,
                    onRedact: { regions in
                        editor.addRedaction(
                            regions: regions.map(LiveTextFrame.canvasRect(for:))
                        )
                    }
                )
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
        .task(id: editor.document.sourceAssetID) {
            liveTextSpans = await model.indexedText(
                at: .zero,
                in: editor.document.sourceAssetID
            )
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 11) {
            Button {
                model.closeImageEditor()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(ReelIconButtonStyle())
            .help("Back to Photos")

            Image(systemName: "photo")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(theme.palette.surfaceRaised)
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                EditableFileTitle(
                    name: model.assets.first(where: {
                        $0.id == editor.document.sourceAssetID
                    })?.displayName ?? editor.sourceURL.lastPathComponent,
                    accessibilityIdentifier: "image-file-title",
                    onCommit: { model.renameAsset(editor.document.sourceAssetID, to: $0) }
                )
                HStack(spacing: 5) {
                    Circle()
                        .fill(editor.isRendering ? theme.palette.click : theme.palette.success)
                        .frame(width: 5, height: 5)
                    Text(
                        editor.isRendering
                            ? "Updating preview…"
                            : "\(editor.document.canvas.width) × \(editor.document.canvas.height) · Saved"
                    )
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                Button {
                    editor.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(ReelIconButtonStyle())
                .disabled(
                    model.renamingAssetIDs.contains(editor.document.sourceAssetID)
                        || !editor.undoManager.canUndo
                )
                .help("Undo")

                Button {
                    editor.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(ReelIconButtonStyle())
                .disabled(
                    model.renamingAssetIDs.contains(editor.document.sourceAssetID)
                        || !editor.undoManager.canRedo
                )
                .help("Redo")
            }

            Button(action: export) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ReelProminentButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: EditorChromeMetrics.headerHeight)
        .background(theme.palette.surfacePanel)
    }

    private var toolOptionsBar: some View {
        HStack(spacing: 10) {
            Label(editor.activeTool.title, systemImage: editor.activeTool.symbol)
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textPrimary)

            Rectangle()
                .fill(theme.palette.line)
                .frame(width: theme.metrics.hairline, height: 18)

            Text(editor.activeTool.guidance)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 10)
            toolControls
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(theme.palette.surfacePanel.opacity(0.96))
    }

    @ViewBuilder private var toolControls: some View {
        switch editor.activeTool {
        case .select:
            HStack(spacing: 5) {
                Button {
                    editor.duplicateSelectedLayer()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.selectedLayer == nil)

                Button {
                    editor.removeSelectedLayer()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ReelIconButtonStyle())
                .disabled(editor.selectedLayer == nil)
                .help("Delete Selected Layer")
            }

        case .crop:
            HStack(spacing: 6) {
                Menu {
                    Button("Freeform") { editor.stageCrop(aspectRatio: nil) }
                    Button("Square") { editor.stageCrop(aspectRatio: 1) }
                    Button("16:9") { editor.stageCrop(aspectRatio: 16.0 / 9.0) }
                    Button("4:3") { editor.stageCrop(aspectRatio: 4.0 / 3.0) }
                    Button("3:2") { editor.stageCrop(aspectRatio: 3.0 / 2.0) }
                } label: {
                    Label("Aspect", systemImage: "aspectratio")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button("Reset") { editor.resetCrop() }
                    .buttonStyle(ReelBorderedButtonStyle())

                if editor.pendingCrop != nil {
                    Button("Cancel") { editor.cancelPendingCrop() }
                        .buttonStyle(ReelBorderedButtonStyle())
                    Button("Apply") { editor.applyPendingCrop() }
                        .buttonStyle(ReelProminentButtonStyle())
                }
            }

        case .arrow, .box, .ellipse, .freehand:
            HStack(spacing: 8) {
                editorColorPicker
                Text("Size")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                Slider(value: $editor.strokeWidth, in: 1...18, step: 1)
                    .frame(width: 92)
                Text("\(Int(editor.strokeWidth)) px")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }

        case .text, .highlight, .step:
            HStack(spacing: 7) {
                Text("Color")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                editorColorPicker
            }

        case .redact:
            Picker("Style", selection: $editor.redactionMode) {
                ForEach(ImageRedactionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

        case .blur:
            HStack(spacing: 8) {
                Text("Strength")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                Slider(value: $editor.blurRadius, in: 4...48, step: 2)
                    .frame(width: 110)
                Text("\(Int(editor.blurRadius))")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 22, alignment: .trailing)
            }

        case .padding:
            Button {
                editor.addPadding()
            } label: {
                Label("Add Background", systemImage: "plus")
            }
            .buttonStyle(ReelProminentButtonStyle())

        case .pan, .eyedropper:
            EmptyView()
        }
    }

    private var editorColorPicker: some View {
        ColorPicker("Color", selection: activeColorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 26)
    }

    private var activeColorBinding: Binding<Color> {
        Binding(
            get: { Color(editorRGBA: editor.activeColor) },
            set: { editor.activeColor = $0.editorRGBA }
        )
    }

    private var toolRail: some View {
        ScrollView {
            VStack(spacing: 7) {
                ForEach(Array(ImageEditorTool.grouped.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.palette.line)
                            .frame(width: 24, height: theme.metrics.hairline)
                            .padding(.vertical, 1)
                    }
                    ForEach(group) { tool in
                        Button {
                            editor.activate(tool)
                        } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 38, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ReelIconButtonStyle(isActive: editor.activeTool == tool))
                        .overlay(alignment: .leading) {
                            if editor.activeTool == tool {
                                Capsule()
                                    .fill(theme.palette.accent)
                                    .frame(width: 2, height: 18)
                                    .offset(x: -4)
                            }
                        }
                        .help("\(tool.title) — \(tool.guidance)")
                        .accessibilityLabel(tool.title)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .frame(width: 56)
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
    @Binding var zoomLevel: Double
    let liveTextSpans: [OCRSpan]
    let onSearch: (String) -> Void
    let onRedact: ([NormalizedRect]) -> Void
    @State private var draftPoints: [CGPoint] = []
    @State private var movingLayerID: LayerID?
    @State private var selectionTranslation = CGPoint.zero
    @State private var magnificationStart = 1.0

    var body: some View {
        GeometryReader { proxy in
            if let rendered = editor.renderedImage {
                let fit = fittedSize(
                    imageSize: CGSize(width: rendered.width, height: rendered.height),
                    in: proxy.size
                )
                let artboardSize = CGSize(
                    width: fit.width * zoomLevel,
                    height: fit.height * zoomLevel
                )
                let workspaceSize = CGSize(
                    width: max(proxy.size.width, artboardSize.width + 128),
                    height: max(proxy.size.height, artboardSize.height + 128)
                )

                ScrollViewReader { scroller in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            CanvasBackdrop()
                            artboard(rendered, size: artboardSize)
                                .position(x: workspaceSize.width / 2, y: workspaceSize.height / 2)
                            // Anchoring on the artboard centre keeps the picture in
                            // view when a zoom change resizes the scrollable area.
                            Color.clear
                                .frame(width: 1, height: 1)
                                .position(x: workspaceSize.width / 2, y: workspaceSize.height / 2)
                                .id(Self.centerAnchor)
                            ScrollViewPanBridge(isEnabled: editor.activeTool == .pan)
                                .frame(width: 0, height: 0)
                        }
                        .frame(width: workspaceSize.width, height: workspaceSize.height)
                    }
                    .scrollIndicators(.never)
                    .background(theme.palette.surfaceSunken)
                    .simultaneousGesture(magnificationGesture)
                    .onChange(of: zoomLevel) { _, _ in
                        scroller.scrollTo(Self.centerAnchor, anchor: .center)
                    }
                    .overlay(alignment: .topTrailing) {
                        canvasInfoBadge
                            .padding(12)
                    }
                    .overlay(alignment: .bottom) {
                        zoomControls(scroller: scroller)
                            .padding(.bottom, 14)
                    }
                }
            } else {
                ZStack {
                    theme.palette.surfaceSunken
                    ProgressView("Preparing canvas…")
                        .controlSize(.small)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .onDeleteCommand { editor.removeSelectedLayer() }
        .onMoveCommand { direction in
            guard editor.activeTool == .select else { return }
            let amount: CGFloat = 0.005
            switch direction {
            case .left: editor.moveSelectedLayer(by: CGPoint(x: -amount, y: 0))
            case .right: editor.moveSelectedLayer(by: CGPoint(x: amount, y: 0))
            case .up: editor.moveSelectedLayer(by: CGPoint(x: 0, y: -amount))
            case .down: editor.moveSelectedLayer(by: CGPoint(x: 0, y: amount))
            @unknown default: break
            }
        }
    }

    private func artboard(_ image: CGImage, size: CGSize) -> some View {
        ZStack {
            Checkerboard()
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)

            if editor.activeTool == .select, !liveTextSpans.isEmpty {
                LiveTextOverlay(
                    spans: liveTextSpans,
                    onSearch: onSearch,
                    onRedact: onRedact
                )
            }

            if editor.activeTool == .crop, let crop = editor.pendingCrop {
                CropOverlay(crop: crop)
            } else {
                draftOverlay
                selectionOverlay
            }

            if editor.isRendering {
                Color.black.opacity(0.08)
                ProgressView()
                    .controlSize(.small)
                    .padding(9)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.small, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.small, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
        .overlay(alignment: .bottomLeading) {
            if editor.activeTool == .select, !liveTextSpans.isEmpty {
                Label("Live Text · Drag to select", systemImage: "text.viewfinder")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 9)
                    .background(theme.palette.surfacePanel.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(interactionGesture(in: size))
    }

    @ViewBuilder private var draftOverlay: some View {
        if !draftPoints.isEmpty {
            GeometryReader { proxy in
                Canvas { context, size in
                    let color = Color(editorRGBA: editor.activeColor).opacity(0.9)
                    let rect = pixelBounds(for: draftPoints, in: size)
                    switch editor.activeTool {
                    case .freehand, .arrow:
                        var path = Path()
                        if let first = draftPoints.first {
                            path.move(to: pixelPoint(first, in: size))
                            for point in draftPoints.dropFirst() {
                                path.addLine(to: pixelPoint(point, in: size))
                            }
                            context.stroke(
                                path,
                                with: .color(color),
                                style: StrokeStyle(
                                    lineWidth: editor.strokeWidth,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        }
                    case .ellipse:
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(color),
                            lineWidth: editor.strokeWidth
                        )
                    case .step:
                        let center = draftPoints.last.map { pixelPoint($0, in: size) } ?? .zero
                        let badge = CGRect(
                            x: center.x - 15, y: center.y - 15, width: 30, height: 30)
                        context.fill(Path(ellipseIn: badge), with: .color(color))
                    case .highlight:
                        context.fill(Path(rect), with: .color(color.opacity(0.3)))
                    case .redact, .blur:
                        context.fill(Path(rect), with: .color(.black.opacity(0.28)))
                        context.stroke(
                            Path(rect),
                            with: .color(.white.opacity(0.72)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    default:
                        context.stroke(
                            Path(rect),
                            with: .color(color),
                            lineWidth: max(editor.strokeWidth, 1)
                        )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var selectionOverlay: some View {
        if editor.activeTool == .select, let layer = editor.selectedLayer {
            GeometryReader { proxy in
                let normalized = layer.editorBounds(canvas: editor.document.canvas)
                let rect = CGRect(
                    x: normalized.minX * proxy.size.width + selectionTranslation.x
                        * proxy.size.width,
                    y: normalized.minY * proxy.size.height + selectionTranslation.y
                        * proxy.size.height,
                    width: max(normalized.width * proxy.size.width, 12),
                    height: max(normalized.height * proxy.size.height, 12)
                ).insetBy(dx: -4, dy: -4)

                ZStack {
                    // Marching ants rather than a tinted outline: the artwork
                    // underneath can be any colour, so the marker carries its
                    // own contrast instead of relying on the theme.
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.small, style: .continuous
                    )
                    .stroke(.black.opacity(0.5), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.small, style: .continuous
                    )
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    ForEach(Array(rect.handlePoints.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                            .frame(width: 7, height: 7)
                            .position(point)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func interactionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = normalized(value.startLocation, in: size)
                let current = normalized(value.location, in: size)
                switch editor.activeTool {
                case .pan:
                    break
                case .select:
                    if movingLayerID == nil {
                        editor.selectLayer(at: start)
                        movingLayerID = editor.selectedLayerID
                    }
                    selectionTranslation = CGPoint(
                        x: value.translation.width / size.width,
                        y: value.translation.height / size.height
                    )
                case .crop:
                    editor.stageCrop(normalizedRect(from: start, to: current))
                case .freehand:
                    if draftPoints.isEmpty { draftPoints = [start] }
                    if let last = draftPoints.last,
                        hypot(
                            (current.x - last.x) * size.width,
                            (current.y - last.y) * size.height
                        ) > 1.5
                    {
                        draftPoints.append(current)
                    }
                case .padding, .eyedropper:
                    break
                default:
                    draftPoints = [start, current]
                }
            }
            .onEnded { value in
                defer {
                    draftPoints = []
                    movingLayerID = nil
                    selectionTranslation = .zero
                }
                let start = normalized(value.startLocation, in: size)
                let end = normalized(value.location, in: size)
                switch editor.activeTool {
                case .pan:
                    break
                case .select:
                    guard movingLayerID != nil,
                        hypot(value.translation.width, value.translation.height) > 2
                    else { return }
                    editor.moveSelectedLayer(
                        by: CGPoint(
                            x: value.translation.width / size.width,
                            y: value.translation.height / size.height
                        )
                    )
                case .crop, .padding:
                    break
                case .eyedropper:
                    editor.sampleColor(at: end)
                case .freehand:
                    editor.commitGesture(points: draftPoints + [end])
                default:
                    editor.commitGesture(points: [start, end])
                }
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomLevel = CanvasZoom.pinched(from: magnificationStart, magnification: value)
            }
            .onEnded { _ in magnificationStart = zoomLevel }
    }

    private var canvasInfoBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text("\(editor.document.canvas.width) × \(editor.document.canvas.height)")
        }
        .font(theme.type.numeric.font)
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(theme.palette.surfacePanel.opacity(0.94))
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
    }

    private func zoomControls(scroller: ScrollViewProxy) -> some View {
        HStack(spacing: 5) {
            Button {
                setZoom(CanvasZoom.zoomedOut(from: zoomLevel))
            } label: {
                Image(systemName: "minus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(zoomLevel <= CanvasZoom.minimum)
            .help("Zoom out")

            Slider(value: zoomExponent, in: CanvasZoom.exponentRange)
                .frame(width: 112)
                .accessibilityLabel("Zoom")
                .accessibilityValue(zoomPercentage)

            Button {
                setZoom(CanvasZoom.zoomedIn(from: zoomLevel))
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(zoomLevel >= CanvasZoom.maximum)
            .help("Zoom in")

            Text(zoomPercentage)
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 42, alignment: .trailing)

            Button("Recenter") { recenter(scroller) }
                .buttonStyle(ReelPlainButtonStyle())
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, 4)
                .help("Bring the image back to the middle of the canvas")

            Button("Fit") {
                setZoom(CanvasZoom.fit)
                recenter(scroller)
            }
            .buttonStyle(ReelPlainButtonStyle())
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 4)
            .help("Fit the whole image in the canvas")
        }
        .padding(5)
        .background(theme.palette.surfacePanel.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .strokeBorder(theme.palette.lineStrong, lineWidth: theme.metrics.hairline)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private static let centerAnchor = "canvas.center"

    private var zoomPercentage: String {
        "\(Int((zoomLevel * 100).rounded()))%"
    }

    /// Drives the slider in octaves so the track is evenly split either side of 100%.
    private var zoomExponent: Binding<Double> {
        Binding(
            get: { CanvasZoom.exponent(for: zoomLevel) },
            set: { exponent in
                zoomLevel = CanvasZoom.value(forExponent: exponent)
                magnificationStart = zoomLevel
            }
        )
    }

    private func setZoom(_ value: Double) {
        withAnimation(.smooth(duration: 0.2)) {
            zoomLevel = CanvasZoom.clamped(value)
            magnificationStart = zoomLevel
        }
    }

    private func recenter(_ scroller: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.25)) {
            scroller.scrollTo(Self.centerAnchor, anchor: .center)
        }
    }

    private func fittedSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let available = CGSize(
            width: max(container.width - 112, 120),
            height: max(container.height - 112, 120)
        )
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func pixelPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func pixelBounds(for points: [CGPoint], in size: CGSize) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: pixelPoint(first, in: size), size: .zero)) {
            result, point in
            result.union(CGRect(origin: pixelPoint(point, in: size), size: .zero))
        }
    }
}

private struct CanvasBackdrop: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                    let dot = CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.palette.lineStrong))
                }
            }
        }
        .background(theme.palette.surfaceSunken)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.12)))
            let cell: CGFloat = 12
            for row in 0...Int(ceil(size.height / cell)) {
                for column in 0...Int(ceil(size.width / cell))
                where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(.black.opacity(0.08)))
                }
            }
        }
    }
}

private struct CropOverlay: View {
    @Environment(\.theme) private var theme
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(
                x: crop.minX * proxy.size.width,
                y: crop.minY * proxy.size.height,
                width: crop.width * proxy.size.width,
                height: crop.height * proxy.size.height
            )
            Canvas { context, size in
                var outside = Path()
                outside.addRect(CGRect(origin: .zero, size: size))
                outside.addRect(rect)
                context.fill(
                    outside,
                    with: .color(.black.opacity(0.52)),
                    style: FillStyle(eoFill: true)
                )
                context.stroke(Path(rect), with: .color(.white.opacity(0.92)), lineWidth: 1)
                var guides = Path()
                guides.move(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY))
                guides.addLine(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.maxY))
                guides.move(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.minY))
                guides.addLine(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY))
                guides.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height / 3))
                guides.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height / 3))
                guides.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 2 / 3))
                guides.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 2 / 3))
                context.stroke(guides, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
            ForEach(Array(rect.handlePoints.enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Lets the system's accessibility drag (including Three-Finger Drag) scroll a
/// SwiftUI canvas without stealing draw and selection drags in the other tools.
private struct ScrollViewPanBridge: NSViewRepresentable {
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.owner = context.coordinator
        view.isPanEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.owner = context.coordinator
        view.isPanEnabled = isEnabled
        context.coordinator.attach(to: view.enclosingScrollView, enabled: isEnabled)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: NSView {
        weak var owner: Coordinator?
        var isPanEnabled = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            owner?.attach(to: enclosingScrollView, enabled: isPanEnabled)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var recognizer: NSPanGestureRecognizer?
        private var startOrigin = NSPoint.zero

        func attach(to nextScrollView: NSScrollView?, enabled: Bool) {
            if scrollView !== nextScrollView {
                detach()
                guard let nextScrollView else { return }
                let recognizer = NSPanGestureRecognizer(
                    target: self,
                    action: #selector(handlePan(_:))
                )
                recognizer.buttonMask = 0x1
                recognizer.delaysPrimaryMouseButtonEvents = true
                nextScrollView.addGestureRecognizer(recognizer)
                scrollView = nextScrollView
                self.recognizer = recognizer
            }
            recognizer?.isEnabled = enabled
        }

        func detach() {
            if let recognizer {
                scrollView?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
        }

        @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            switch recognizer.state {
            case .began:
                startOrigin = clipView.bounds.origin
            case .changed:
                let translation = recognizer.translation(in: clipView)
                var bounds = clipView.bounds
                bounds.origin = NSPoint(
                    x: startOrigin.x - translation.x,
                    y: startOrigin.y - translation.y
                )
                let constrained = clipView.constrainBoundsRect(bounds)
                clipView.scroll(to: constrained.origin)
                scrollView.reflectScrolledClipView(clipView)
            case .possible, .ended, .cancelled, .failed:
                break
            @unknown default:
                break
            }
        }
    }
}

extension ImageEditorTool {
    fileprivate static let grouped: [[ImageEditorTool]] = [
        [.select, .pan, .crop],
        [.arrow, .box, .ellipse, .freehand, .text, .highlight, .step],
        [.redact, .blur],
        [.padding, .eyedropper],
    ]

    fileprivate var guidance: String {
        switch self {
        case .select: "Click a layer to select it, then drag to move it."
        case .pan: "Use Three-Finger Drag or a mouse drag to move around the canvas."
        case .crop: "Drag a crop area or choose an aspect ratio, then Apply."
        case .arrow: "Drag from the start point toward what you want to call out."
        case .box: "Drag around an area to draw a box."
        case .ellipse: "Drag around an area to draw an ellipse."
        case .freehand: "Draw directly on the screenshot."
        case .text: "Click or drag to add text, then edit it in the inspector."
        case .highlight: "Drag over an area to highlight it."
        case .step: "Click once to place the next numbered step."
        case .redact: "Drag over sensitive content to permanently flatten it on export."
        case .blur: "Drag over an area to blur it."
        case .padding: "Add a polished background frame around the screenshot."
        case .eyedropper: "Click the screenshot to sample a color."
        }
    }
}

extension Layer {
    fileprivate func editorBounds(canvas: ImageCanvas) -> CGRect {
        let bounds: CGRect
        switch self {
        case .annotation(let value): bounds = value.bounds
        case .text(let value): bounds = value.frame
        case .highlight(let value): bounds = value.regions.editorUnion
        case .redaction(let value): bounds = value.regions.editorUnion
        case .blur(let value): bounds = value.regions.editorUnion
        case .padding: bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .step(let value):
            let diameter = CGFloat(value.diameter) / CGFloat(min(canvas.width, canvas.height))
            bounds = CGRect(
                x: value.position.x - diameter / 2,
                y: value.position.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
        return bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

extension Array where Element == CGRect {
    fileprivate var editorUnion: CGRect {
        guard let first else { return .zero }
        return dropFirst().reduce(first) { $0.union($1) }
    }
}

extension CGRect {
    fileprivate var handlePoints: [CGPoint] {
        [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: maxY),
            CGPoint(x: maxX, y: maxY),
        ]
    }
}

extension Color {
    fileprivate init(editorRGBA color: RGBA) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }

    fileprivate var editorRGBA: RGBA {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return RGBA(r: 1, g: 0.29, b: 0.25, a: 1)
        }
        return RGBA(
            r: Double(color.redComponent),
            g: Double(color.greenComponent),
            b: Double(color.blueComponent),
            a: Double(color.alphaComponent)
        )
    }
}
