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
            Text(editor.document.title)
                .font(theme.type.label.font)
                .lineLimit(1)
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
            Button("Save As PDF…", action: saveAsPDF)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.isExporting)
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
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
                Button {
                    editor.deleteSelectedPage()
                } label: {
                    Image(systemName: "trash")
                }
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
                    help: tool.help,
                    isActive: editor.activeTool == tool
                ) {
                    editor.activeTool = tool
                }
            }
            Divider().overlay(theme.palette.line).padding(.vertical, 5)
            PDFToolButton(systemName: "rotate.right", help: "Rotate page") {
                editor.rotateSelectedPage()
            }
            PDFToolButton(systemName: "arrow.up", help: "Move page earlier") {
                editor.moveSelectedPage(by: -1)
            }
            PDFToolButton(systemName: "arrow.down", help: "Move page later") {
                editor.moveSelectedPage(by: 1)
            }
            Divider().overlay(theme.palette.line).padding(.vertical, 5)
            PDFToolButton(systemName: "doc.text.magnifyingglass", help: "OCR this page") {
                editor.recognizeSelectedPage()
            }
            PDFToolButton(systemName: "text.document", help: "Export Markdown") {
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
            ZStack {
                theme.palette.surfaceSunken
                if let image = editor.renderedPage {
                    let frame = fittedRect(
                        imageSize: CGSize(width: image.width, height: image.height),
                        container: proxy.size
                    )
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(editGesture(in: frame))
                        .onTapGesture {
                            commitInlineTextEdit()
                            editor.selectSourceTextBlock(nil)
                            editor.selectLayer(nil)
                        }
                    if editor.activeTool == .select {
                        ForEach(editor.editableTextBlocks) { block in
                            sourceTextOverlay(block, pageFrame: frame)
                        }
                    }
                } else if editor.isRendering {
                    ProgressView()
                }
            }
        }
        .padding(24)
        .onChange(of: isInlineTextFocused) { _, focused in
            if !focused { commitInlineTextEdit() }
        }
        .onExitCommand {
            cancelInlineTextEdit()
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

    private func fittedRect(imageSize: CGSize, container: CGSize) -> CGRect {
        let available = CGSize(
            width: max(container.width - 48, 1),
            height: max(container.height - 48, 1)
        )
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
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
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(ReelIconButtonStyle(isActive: isActive))
        .help(help)
    }
}
