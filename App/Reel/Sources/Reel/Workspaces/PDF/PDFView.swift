import AppKit
import CoreModel
import DesignSystem
import LibraryStore
import PDFEngine
import ReelAppCore
import SwiftUI
import UniformTypeIdentifiers

struct PDFView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        if let editor = model.pdfEditor {
            PDFEditorView(model: model, editor: editor)
        } else {
            library
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.isSearching {
                WorkspaceDropZone(model: model, workspace: .pdf)
                HStack(spacing: theme.metrics.spacing.sm) {
                    Button("Open editor") {
                        guard let selectedPDF else { return }
                        model.openPDFEditor(for: selectedPDF.id)
                    }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(selectedPDF == nil)
                }
                .padding(.top, 12)
            }
            AssetGrid(
                model: model,
                assets: model.visibleAssets.filter { $0.kind == .document }
            )
            .padding(.top, 24)
        }
    }

    private var selectedPDF: AssetRecord? {
        guard let selectedAssetID = model.selectedAssetID else { return nil }
        return model.assets.first {
            $0.id.rawValue == selectedAssetID && $0.kind == .document
        }
    }
}

private struct PDFEditorView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: PDFEditorViewModel
    @State private var dragStart: CGPoint?
    @State private var editingTextObjectID: Int?
    @State private var textDraft = ""
    @State private var zoomLevel = CanvasZoom.fit
    @FocusState private var isInlineTextFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.palette.line)
                HStack(spacing: 0) {
                    thumbnails
                    Divider().overlay(theme.palette.line)
                    toolRail
                    Divider().overlay(theme.palette.line)
                    canvas
                }
            }
            if let notice = editor.notice {
                Toast(notice)
                    .padding(.bottom, 14)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.1))
                        editor.clearNotice()
                    }
            }
        }
        .background(theme.palette.surfaceBase)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closePDFEditor()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .help("Back to PDF library")
            EditableFileTitle(
                name: model.assets.first(where: {
                    $0.id == editor.document.sourceAssetID
                })?.displayName ?? editor.sourceURL.lastPathComponent,
                accessibilityIdentifier: "pdf-file-title",
                onCommit: { model.renameAsset(editor.document.sourceAssetID, to: $0) }
            )
            Text("Page \(editor.selectedPageNumber) of \(editor.document.pages.count)")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            Spacer()
            if editor.isRendering || editor.isExporting || editor.isRecognizingText
                || editor.isExportingMarkdown
            {
                ProgressView().controlSize(.small)
            }
            Button("OCR Page", action: editor.recognizeSelectedPage)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.isRecognizingText)
            Button("Markdown…", action: saveAsMarkdown)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.isExportingMarkdown)
            Button(editor.derivativeURL == nil ? "Save As PDF…" : "Save PDF", action: savePDF)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.isExporting)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("pdf-save")
                .help(
                    editor.derivativeURL == nil
                        ? "Choose a safe destination for the edited copy"
                        : "Save to \(editor.derivativeURL?.lastPathComponent ?? "the edited copy")"
                )
            Menu {
                Button("Save As PDF…", action: saveAsPDF)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .disabled(editor.isExporting)
            .help("Save the edited PDF to a different destination")
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(
                model.renamingAssetIDs.contains(editor.document.sourceAssetID)
                    || !editor.undoManager.canUndo
            )
            .keyboardShortcut("z", modifiers: .command)
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(
                model.renamingAssetIDs.contains(editor.document.sourceAssetID)
                    || !editor.undoManager.canRedo
            )
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .frame(height: EditorChromeMetrics.headerHeight)
        .background(theme.palette.surfacePanel)
    }

    private var thumbnails: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(editor.document.pages.enumerated()), id: \.element.id) {
                        index, page in
                        PDFPageThumbnail(
                            number: index + 1,
                            image: editor.thumbnails[page.id],
                            isSelected: page.id == editor.selectedPageID
                        ) {
                            editor.selectPage(page.id)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            HStack(spacing: 8) {
                Button {
                    editor.addBlankPage()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a blank page")
                Button {
                    editor.duplicateSelectedPage()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate selected page")
                .accessibilityLabel("Duplicate selected page")
                .accessibilityIdentifier("pdf-duplicate-page")
                Button {
                    editor.deleteSelectedPage()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected page")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .padding(.bottom, 10)
        }
        .frame(width: 124)
        .background(theme.palette.surfacePanel)
    }

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(PDFEditorTool.allCases) { tool in
                PDFToolButton(
                    systemName: tool.symbol,
                    title: tool.title,
                    help: tool.help,
                    isActive: editor.activeTool == tool,
                    accessibilityIdentifier: "pdf-tool-\(tool.rawValue)"
                ) {
                    editor.activeTool = tool
                }
            }
            Divider().overlay(theme.palette.line).padding(.vertical, 5)
            PDFToolButton(systemName: "rotate.right", title: "Rotate", help: "Rotate page") {
                editor.rotateSelectedPage()
            }
            PDFToolButton(
                systemName: "arrow.up",
                title: "Move Earlier",
                help: "Move page earlier"
            ) {
                editor.moveSelectedPage(by: -1)
            }
            PDFToolButton(systemName: "arrow.down", title: "Move Later", help: "Move page later") {
                editor.moveSelectedPage(by: 1)
            }
            PDFToolButton(
                systemName: "plus.square.on.square",
                title: "Duplicate",
                help: "Duplicate selected page"
            ) {
                editor.duplicateSelectedPage()
            }
            Divider().overlay(theme.palette.line).padding(.vertical, 5)
            PDFToolButton(
                systemName: "doc.text.magnifyingglass",
                title: "OCR",
                help: "OCR this page"
            ) {
                editor.recognizeSelectedPage()
            }
            PDFToolButton(
                systemName: "text.document",
                title: "Export Markdown",
                help: "Export Markdown"
            ) {
                saveAsMarkdown()
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 44)
        .background(theme.palette.surfacePanel)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            if let image = editor.renderedPage {
                let fit = fittedSize(
                    imageSize: CGSize(width: image.width, height: image.height),
                    container: proxy.size
                )
                let pageSize = CGSize(
                    width: fit.width * zoomLevel,
                    height: fit.height * zoomLevel
                )
                let workspaceSize = CGSize(
                    width: max(proxy.size.width, pageSize.width + 128),
                    height: max(proxy.size.height, pageSize.height + 128)
                )
                ScrollViewReader { scroller in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            theme.palette.surfaceSunken
                            pageCanvas(image, size: pageSize)
                                .position(
                                    x: workspaceSize.width / 2,
                                    y: workspaceSize.height / 2
                                )
                            Color.clear
                                .frame(width: 1, height: 1)
                                .position(
                                    x: workspaceSize.width / 2,
                                    y: workspaceSize.height / 2
                                )
                                .id(Self.pageCenterAnchor)
                        }
                        .frame(width: workspaceSize.width, height: workspaceSize.height)
                        .background(PDFMagnificationBridge(zoomLevel: $zoomLevel))
                    }
                    .scrollIndicators(.visible)
                    .background(theme.palette.surfaceSunken)
                    .overlay(alignment: .topLeading) {
                        activeToolHint
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        zoomControls(scroller: scroller)
                            .padding(.bottom, 14)
                    }
                }
            } else {
                ZStack {
                    theme.palette.surfaceSunken
                    if editor.isRendering { ProgressView() }
                }
            }
        }
        .onChange(of: isInlineTextFocused) { _, focused in
            if !focused { commitInlineTextEdit() }
        }
        .onExitCommand {
            cancelInlineTextEdit()
        }
    }

    private func pageCanvas(_ image: CGImage, size: CGSize) -> some View {
        let frame = CGRect(origin: .zero, size: size)
        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .gesture(editGesture(in: frame))
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handlePageTap(value.location, in: size)
                        }
                )
            if editor.activeTool == .select {
                ForEach(editor.editableTextBlocks) { block in
                    sourceTextOverlay(block, pageFrame: frame)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
    }

    private func handlePageTap(_ point: CGPoint, in size: CGSize) {
        commitInlineTextEdit()
        editor.selectSourceTextBlock(nil)
        if editor.activeTool == .text {
            _ = editor.addText(at: normalized(point, in: size))
        } else {
            editor.selectLayer(nil)
        }
    }

    private func sourceTextOverlay(
        _ block: PDFTextBlock,
        pageFrame: CGRect
    ) -> some View {
        let normalizedBounds = displayBounds(
            block.bounds,
            rotation: editor.selectedPage?.rotation ?? .degrees0
        )
        let blockFrame = CGRect(
            x: pageFrame.minX + normalizedBounds.minX * pageFrame.width,
            y: pageFrame.minY + normalizedBounds.minY * pageFrame.height,
            width: max(normalizedBounds.width * pageFrame.width, 18),
            height: max(normalizedBounds.height * pageFrame.height, 16)
        )
        let isSelected = editor.selectedSourceTextBlockID == block.pageObjectIndex
        return ZStack {
            if editingTextObjectID == block.pageObjectIndex {
                TextField("PDF text", text: $textDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(min(blockFrame.height * 0.72, 24), 11)))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(
                        minWidth: max(blockFrame.width, 150),
                        minHeight: max(blockFrame.height, 30),
                        alignment: .leading
                    )
                    .background(theme.palette.surfaceRaised.opacity(0.98))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.control,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.control,
                            style: .continuous
                        )
                        .strokeBorder(theme.palette.accent, lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                    .focused($isInlineTextFocused)
                    .onSubmit(commitInlineTextEdit)
                    .accessibilityIdentifier("pdf-inline-text-editor")
            } else {
                RoundedRectangle(
                    cornerRadius: theme.metrics.radius.small,
                    style: .continuous
                )
                .fill(isSelected ? theme.palette.accentDim.opacity(0.28) : Color.clear)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.small,
                        style: .continuous
                    )
                    .strokeBorder(
                        isSelected ? theme.palette.accent : Color.clear,
                        lineWidth: 1
                    )
                }
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .exclusively(before: TapGesture())
                        .onEnded { value in
                            switch value {
                            case .first:
                                beginInlineTextEdit(block)
                            case .second:
                                commitInlineTextEdit()
                                editor.selectSourceTextBlock(block.pageObjectIndex)
                            }
                        }
                )
                .accessibilityAction {
                    commitInlineTextEdit()
                    editor.selectSourceTextBlock(block.pageObjectIndex)
                }
                .help("Double-click to edit “\(block.text.prefix(60))”")
                .accessibilityLabel("PDF text: \(block.text)")
                .accessibilityHint("Double-click to edit this text in place")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(width: blockFrame.width, height: blockFrame.height)
        .position(x: blockFrame.midX, y: blockFrame.midY)
        .zIndex(editingTextObjectID == block.pageObjectIndex ? 4 : 2)
    }

    private func beginInlineTextEdit(_ block: PDFTextBlock) {
        commitInlineTextEdit()
        editor.selectSourceTextBlock(block.pageObjectIndex)
        editingTextObjectID = block.pageObjectIndex
        textDraft = block.text
        Task { @MainActor in isInlineTextFocused = true }
    }

    private func commitInlineTextEdit() {
        guard let editingTextObjectID else { return }
        let value = textDraft
        self.editingTextObjectID = nil
        isInlineTextFocused = false
        editor.replaceSourceText(objectIndex: editingTextObjectID, with: value)
    }

    private func cancelInlineTextEdit() {
        editingTextObjectID = nil
        textDraft = ""
        isInlineTextFocused = false
    }

    private func displayBounds(_ rect: CGRect, rotation: PDFPageRotation) -> CGRect {
        switch rotation {
        case .degrees0:
            return rect
        case .degrees90:
            return CGRect(
                x: 1 - rect.maxY,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case .degrees180:
            return CGRect(
                x: 1 - rect.maxX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        case .degrees270:
            return CGRect(
                x: rect.minY,
                y: 1 - rect.maxX,
                width: rect.height,
                height: rect.width
            )
        }
    }

    private func editGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil { dragStart = normalized(value.startLocation, in: frame.size) }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                editor.commitGesture(
                    from: start,
                    to: normalized(value.location, in: frame.size)
                )
                dragStart = nil
            }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0), 1),
            y: min(max(point.y / max(size.height, 1), 0), 1)
        )
    }

    private var activeToolHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: editor.activeTool.symbol)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.activeTool.title)
                    .font(theme.type.label.font)
                Text(editor.activeTool.help)
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.palette.textPrimary)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(maxWidth: 340, alignment: .leading)
        .background(theme.palette.surfacePanel.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(editor.activeTool.help)
    }

    private func zoomControls(scroller: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Button {
                setZoom(CanvasZoom.zoomedOut(from: zoomLevel))
            } label: {
                Image(systemName: "minus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(zoomLevel <= CanvasZoom.minimum)
            .help("Zoom out")

            Slider(
                value: Binding(
                    get: { CanvasZoom.exponent(for: zoomLevel) },
                    set: { setZoom(CanvasZoom.value(forExponent: $0)) }
                ),
                in: CanvasZoom.exponentRange
            )
            .frame(width: 112)
            .accessibilityLabel("PDF zoom")
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

            Button("Fit") {
                setZoom(CanvasZoom.fit)
                scroller.scrollTo(Self.pageCenterAnchor, anchor: .center)
            }
            .buttonStyle(ReelPlainButtonStyle())
            .font(theme.type.caption.font)
            .help("Fit the whole page")
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

    private static let pageCenterAnchor = "pdf-page-center"

    private var zoomPercentage: String {
        "\(Int((zoomLevel * 100).rounded()))%"
    }

    private func setZoom(_ value: Double) {
        withAnimation(.smooth(duration: 0.18)) {
            zoomLevel = CanvasZoom.clamped(value)
        }
    }

    private func fittedSize(imageSize: CGSize, container: CGSize) -> CGSize {
        let available = CGSize(
            width: max(container.width - 80, 120),
            height: max(container.height - 80, 120)
        )
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func savePDF() {
        if !editor.saveToLastDerivative() { saveAsPDF() }
    }

    private func saveAsPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(editor.document.title)-edited.pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.export(to: url)
        }
    }

    private func saveAsMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(editor.document.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.exportMarkdown(to: url)
        }
    }
}

private struct PDFMagnificationBridge: NSViewRepresentable {
    @Binding var zoomLevel: Double

    func makeNSView(context: Context) -> PDFMagnificationCaptureView {
        let view = PDFMagnificationCaptureView()
        update(view)
        return view
    }

    func updateNSView(_ view: PDFMagnificationCaptureView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: PDFMagnificationCaptureView, coordinator: ()) {
        view.stopMonitoring()
    }

    private func update(_ view: PDFMagnificationCaptureView) {
        view.currentZoom = { zoomLevel }
        view.setZoom = { zoomLevel = CanvasZoom.clamped($0) }
    }
}

@MainActor
private final class PDFMagnificationCaptureView: NSView {
    var currentZoom: () -> Double = { CanvasZoom.fit }
    var setZoom: (Double) -> Void = { _ in }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, consume(event) else { return event }
            return nil
        }
    }

    func stopMonitoring() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard event.window === window,
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return false }
        let clipView = scrollView.contentView
        let clipPoint = clipView.convert(event.locationInWindow, from: nil)
        guard clipView.bounds.contains(clipPoint) else { return false }

        let oldBounds = documentView.bounds
        guard oldBounds.width > 0, oldBounds.height > 0 else { return false }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        let normalized = CGPoint(
            x: (documentPoint.x - oldBounds.minX) / oldBounds.width,
            y: (documentPoint.y - oldBounds.minY) / oldBounds.height
        )
        let viewportOffset = CGPoint(
            x: clipPoint.x - clipView.bounds.minX,
            y: clipPoint.y - clipView.bounds.minY
        )
        let factor = exp(Double(event.magnification) * 0.9)
        let next = CanvasZoom.clamped(currentZoom() * factor)
        guard abs(next - currentZoom()) > 0.000_001 else { return true }
        setZoom(next)

        DispatchQueue.main.async { [weak scrollView, weak documentView] in
            guard let scrollView, let documentView else { return }
            let clipView = scrollView.contentView
            let newBounds = documentView.bounds
            let newPoint = CGPoint(
                x: newBounds.minX + normalized.x * newBounds.width,
                y: newBounds.minY + normalized.y * newBounds.height
            )
            let proposed = NSRect(
                x: newPoint.x - viewportOffset.x,
                y: newPoint.y - viewportOffset.y,
                width: clipView.bounds.width,
                height: clipView.bounds.height
            )
            clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        return true
    }
}

private struct PDFPageThumbnail: View {
    @Environment(\.theme) private var theme
    let number: Int
    let image: CGImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                preview
                    .frame(width: 92, height: 118)
                    .background(Color.white)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.small,
                            style: .continuous
                        )
                        .stroke(
                            isSelected ? theme.palette.accent : theme.palette.line,
                            lineWidth: isSelected ? 2 : 1
                        )
                    }
                Text("\(number)")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .buttonStyle(ReelPlainButtonStyle())
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else {
            Rectangle().fill(theme.palette.surfaceRaised)
        }
    }
}

private struct PDFToolButton: View {
    let systemName: String
    let title: String
    let help: String
    var isActive = false
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(ReelIconButtonStyle(isActive: isActive))
        .help("\(title) — \(help)")
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityIdentifier(accessibilityIdentifier ?? "pdf-action-\(title)")
    }
}
