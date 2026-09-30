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
    @State private var dragCurrent: CGPoint?
    @State private var movingLayerID: PDFLayerID?
    @State private var movingLayerOrigin: CGPoint?
    @State private var editingParagraphID: Int?
    @State private var textDraft = ""
    @State private var inlineCaretOffset: Int?
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
                    .frame(width: 30, height: 30)
            }
            // Matches the back button in every other workspace: the plain style
            // only dips opacity, so this one alone gave no hover fill and no
            // press feedback.
            .buttonStyle(ReelIconButtonStyle())
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
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .accessibilityIdentifier("pdf-save")
                .help(
                    editor.derivativeURL == nil
                        ? "Choose a safe destination for the edited copy"
                        : "Save to \(editor.derivativeURL?.lastPathComponent ?? "the edited copy")"
                )
            // Only worth showing once a destination exists: until then it
            // repeats the button beside it word for word.
            if editor.derivativeURL != nil {
                Menu {
                    Button("Save As PDF…", action: saveAsPDF)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(ReelMenuStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(theme.palette.textSecondary)
                .disabled(editor.isExporting)
                .help("Save the edited PDF to a different destination")
                .accessibilityIdentifier("pdf-more")
            }
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(
                model.renamingAssetIDs.contains(editor.document.sourceAssetID)
                    || !editor.undoManager.canUndo
            )
            .keyboardShortcut("z", modifiers: .command)
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ReelIconButtonStyle())
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
                        .frame(width: 26, height: 26)
                }
                .help("Add a blank page")
                Button {
                    editor.duplicateSelectedPage()
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .frame(width: 26, height: 26)
                }
                .help("Duplicate selected page")
                .accessibilityLabel("Duplicate selected page")
                .accessibilityIdentifier("pdf-duplicate-page")
                Button {
                    editor.deleteSelectedPage()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 26, height: 26)
                }
                .help("Delete selected page")
            }
            .buttonStyle(ReelIconButtonStyle())
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
            if !focused { commitParagraphEdit() }
        }
        .onExitCommand {
            cancelParagraphEdit()
        }
        .onDeleteCommand {
            // While a paragraph is open the key belongs to the text view.
            guard editingParagraphID == nil else { return }
            editor.removeSelectedLayer()
        }
        .background {
            // Command-S belongs to Save, not to Save As. Kept at zero opacity
            // rather than hidden so the key equivalent still registers.
            Button("Save") {
                // Fold any open paragraph into the document first, or the save
                // writes a document that predates what is on screen.
                commitParagraphEdit()
                editor.saveEdits()
            }
            .keyboardShortcut("s", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            if let region = dragPreviewRect(in: frame) {
                dragPreview(region)
            }
            ForEach(placedTextLayers, id: \.id) { layer in
                placedLayerHandle(layer, pageFrame: frame)
            }
            if editor.activeTool == .select, let paragraph = editingParagraph {
                paragraphEditor(paragraph, pageFrame: frame)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
    }

    private func handlePageTap(_ point: CGPoint, in size: CGSize) {
        commitParagraphEdit()
        if editor.activeTool == .text {
            editor.selectSourceTextBlock(nil)
            _ = editor.addText(at: normalized(point, in: size))
            return
        }
        if editor.activeTool == .signature {
            editor.selectSourceTextBlock(nil)
            _ = editor.addSignature(
                editor.signatureName,
                style: editor.signatureStyle,
                at: normalized(point, in: size)
            )
            return
        }
        // Clicking type puts the caret where it was aimed, in the whole
        // paragraph; clicking away from text dismisses instead of opening an
        // empty editor. Editing waits for the page index so a click resolves
        // against finished paragraphs rather than a half-built page.
        if editor.activeTool == .select, editor.isPageIndexed,
            let hit = editor.paragraphHit(at: normalized(point, in: size)),
            let paragraph = editor.pageTextIndex.paragraphs.first(
                where: { $0.id == hit.paragraphID }
            )
        {
            beginParagraphEdit(paragraph, caretOffset: hit.characterOffset)
            return
        }
        editor.selectSourceTextBlock(nil)
        editor.selectLayer(nil)
    }

    /// Text layers the user placed, which can be dragged around the page.
    private var placedTextLayers: [PDFTextLayer] {
        editor.selectedPage?.layers.compactMap { layer in
            guard case .text(let text) = layer, text.sourceReference == nil else { return nil }
            return text
        } ?? []
    }

    /// A drag target over a placed layer, so a signature can be positioned by
    /// hand after it lands.
    private func placedLayerHandle(
        _ layer: PDFTextLayer,
        pageFrame: CGRect
    ) -> some View {
        let bounds = displayBounds(
            layer.frame,
            rotation: editor.selectedPage?.rotation ?? .degrees0
        )
        let box = CGRect(
            x: pageFrame.minX + bounds.minX * pageFrame.width,
            y: pageFrame.minY + bounds.minY * pageFrame.height,
            width: max(bounds.width * pageFrame.width, 16),
            height: max(bounds.height * pageFrame.height, 16)
        )
        let isSelected = editor.selectedLayerID == layer.id
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                Rectangle().strokeBorder(
                    isSelected ? theme.palette.accentLine : Color.clear,
                    lineWidth: theme.metrics.hairline
                )
            }
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if movingLayerID != layer.id {
                            movingLayerID = layer.id
                            movingLayerOrigin = layer.frame.origin
                            editor.selectLayer(layer.id)
                        }
                        guard let origin = movingLayerOrigin else { return }
                        editor.moveLayer(
                            layer.id,
                            to: CGPoint(
                                x: origin.x + value.translation.width / pageFrame.width,
                                y: origin.y + value.translation.height / pageFrame.height
                            )
                        )
                    }
                    .onEnded { _ in
                        movingLayerID = nil
                        movingLayerOrigin = nil
                    }
            )
            .onTapGesture { editor.selectLayer(layer.id) }
            .accessibilityLabel("Placed text: \(layer.text)")
            .zIndex(3)
    }

    private var editingParagraph: PDFTextParagraph? {
        guard let editingParagraphID else { return nil }
        return editor.pageTextIndex.paragraphs.first { $0.id == editingParagraphID }
    }

    /// The paragraph under edit, drawn in place of the glyphs the renderer is
    /// withholding.
    private func paragraphEditor(
        _ paragraph: PDFTextParagraph,
        pageFrame: CGRect
    ) -> some View {
        let bounds = displayBounds(
            paragraph.bounds,
            rotation: editor.selectedPage?.rotation ?? .degrees0
        )
        let box = CGRect(
            x: pageFrame.minX + bounds.minX * pageFrame.width,
            y: pageFrame.minY + bounds.minY * pageFrame.height,
            width: max(bounds.width * pageFrame.width, 24),
            height: max(bounds.height * pageFrame.height, 16)
        )
        // Substituted faces are rarely the exact width of the embedded ones, so
        // the container is given slack past the measured column. Tracking keeps
        // each line the width the page drew it; the slack only stops a rounding
        // difference from clipping the final glyph.
        let slack = pageFrame.maxX - box.minX
        return PDFInlineTextEditor(
            text: $textDraft,
            attributed: attributedParagraph(paragraph, pageFrame: pageFrame),
            caretOffset: inlineCaretOffset,
            onCommit: commitParagraphEdit,
            onCancel: cancelParagraphEdit
        )
        .frame(width: max(box.width, slack), alignment: .topLeading)
        // Height follows the text: constraining it to the measured paragraph
        // clipped the last line whenever the substituted metrics ran taller.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pdf-inline-text-editor")
        .frame(
            width: max(box.width, slack),
            height: box.height,
            alignment: .topLeading
        )
        .position(x: box.minX + max(box.width, slack) / 2, y: box.midY)
        .zIndex(4)
    }

    /// The paragraph styled run by run.
    ///
    /// Attributes are applied over ``PDFTextParagraph/text`` using the span
    /// placements, so the styled string and the string the edit is diffed
    /// against are the same string by construction.
    private func attributedParagraph(
        _ paragraph: PDFTextParagraph,
        pageFrame: CGRect
    ) -> NSAttributedString {
        let text = paragraph.text
        let result = NSMutableAttributedString(string: text)
        for placement in paragraph.spanPlacements {
            guard
                let start = text.index(
                    text.startIndex,
                    offsetBy: placement.start,
                    limitedBy: text.endIndex
                ),
                let end = text.index(start, offsetBy: placement.length, limitedBy: text.endIndex)
            else { continue }
            result.addAttributes(
                [
                    .font: resolvedFont(
                        descriptor: placement.span.font,
                        pdfSize: placement.span.fontSize,
                        pageFrame: pageFrame
                    ),
                    .foregroundColor: NSColor(Color(pdfRGBA: placement.span.color)),
                ],
                range: NSRange(start..<end, in: text)
            )
        }
        applyLineGeometry(paragraph, to: result, pageFrame: pageFrame)
        return result
    }

    /// Pins each line to the leading and indent the page drew it with.
    ///
    /// Without this the editor lays the text out with its own metrics, so the
    /// paragraph visibly shifts the moment it is clicked. Locking line height
    /// to the measured leading and indenting each line to its own left edge
    /// keeps the text where it already was.
    private func applyLineGeometry(
        _ paragraph: PDFTextParagraph,
        to string: NSMutableAttributedString,
        pageFrame: CGRect
    ) {
        let text = string.string
        let placements = paragraph.linePlacements
        let leading = measuredLeading(placements, pageFrame: pageFrame)
        for placement in placements {
            guard
                let start = text.index(
                    text.startIndex,
                    offsetBy: placement.start,
                    limitedBy: text.endIndex
                ),
                let end = text.index(start, offsetBy: placement.length, limitedBy: text.endIndex)
            else { continue }
            let range = NSRange(start..<end, in: text)
            // Fit the run to the width the page gave it. An embedded face is
            // almost never the same width as its substitute, so without this a
            // line either overruns the column and gets clipped or falls short
            // of where it originally ended.
            let target = placement.line.bounds.width * pageFrame.width
            let measured = string.attributedSubstring(from: range).size().width
            if measured > 0, target > 0, abs(measured - target) > 0.5 {
                let spread = CGFloat(max(placement.length - 1, 1))
                string.addAttribute(.kern, value: (target - measured) / spread, range: range)
            }

            let style = NSMutableParagraphStyle()
            if let leading {
                // Add the shortfall between the face's natural line height and
                // the page's leading, rather than overriding the line height.
                // Clamping it compressed every line the substituted face drew
                // taller than the original and lifted the whole paragraph.
                let natural = naturalLineHeight(of: string, in: range)
                if leading > natural {
                    style.lineSpacing = leading - natural
                } else {
                    style.maximumLineHeight = leading
                    style.minimumLineHeight = leading
                }
            }
            let indent = max(
                (placement.line.bounds.minX - paragraph.bounds.minX) * pageFrame.width,
                0
            )
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            // The page already decided where these lines break.
            style.lineBreakMode = .byClipping
            string.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Line height the face in this range lays out with by default.
    private func naturalLineHeight(of string: NSAttributedString, in range: NSRange) -> CGFloat {
        guard range.length > 0,
            let font = string.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { return 0 }
        return NSLayoutManager().defaultLineHeight(for: font)
    }

    /// Distance between consecutive baselines, in view points.
    private func measuredLeading(
        _ placements: [PDFTextParagraph.LinePlacement],
        pageFrame: CGRect
    ) -> CGFloat? {
        // Centres rather than tops: a line's top moves with whichever ascender
        // or capital happens to be on it, which is noise against the leading.
        let centres = placements.map(\.line.bounds.midY)
        guard centres.count > 1 else { return nil }
        let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        let points = median * pageFrame.height
        return points > 1 ? points : nil
    }

    private func beginParagraphEdit(_ paragraph: PDFTextParagraph, caretOffset: Int? = nil) {
        commitParagraphEdit()
        editingParagraphID = paragraph.id
        textDraft = paragraph.text
        inlineCaretOffset = caretOffset
        editor.setEditingSourceObjects(Set(paragraph.pageObjectIndexes))
    }

    private func commitParagraphEdit() {
        guard let paragraph = editingParagraph else { return }
        let value = textDraft
        editingParagraphID = nil
        inlineCaretOffset = nil
        isInlineTextFocused = false
        editor.setEditingSourceObjects([])
        editor.replaceParagraphText(paragraph, with: value)
    }

    private func cancelParagraphEdit() {
        editingParagraphID = nil
        inlineCaretOffset = nil
        textDraft = ""
        isInlineTextFocused = false
        editor.setEditingSourceObjects([])
    }

    /// Screen points per PDF point at the current rendered page size.
    private func pageScale(_ pageFrame: CGRect) -> CGFloat {
        guard let page = editor.selectedPage else { return 1 }
        let isQuarterTurn = page.rotation == .degrees90 || page.rotation == .degrees270
        let pageHeight = isQuarterTurn ? page.size.width : page.size.height
        guard pageHeight > 0, pageFrame.height > 0 else { return 1 }
        return pageFrame.height / pageHeight
    }

    /// The block's own typeface at its own size, mapped onto the rendered page.
    ///
    /// Matching the source font is the point of editing in place. Deriving the
    /// size from the box height instead made every edit render visibly larger
    /// than the text it replaced, and a wrapped block guessed worst of all.
    /// Subset-embedded faces cannot be instantiated under their prefixed
    /// PostScript name, so the base name and family are tried in turn before
    /// falling back to the system face at the correct size.
    private func resolvedFont(
        descriptor: PDFFontDescriptor,
        pdfSize: Double,
        pageFrame: CGRect
    ) -> NSFont {
        let size = max(pdfSize * pageScale(pageFrame), 1)
        var candidates = [descriptor.postScriptName, descriptor.baseFontName]
        if let family = descriptor.familyName { candidates.append(family) }
        for name in candidates where !name.isEmpty {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return fallbackFont(matching: descriptor, size: size)
    }

    /// System font standing in for a face the machine does not have.
    ///
    /// Subset-embedded PDF fonts are rarely installed, so most edits land here.
    /// Falling straight through to the plain system font dropped the weight and
    /// slant, which made an edit inside a bold run render as body text; the
    /// traits are recovered from the face name so the substitute still reads
    /// like the type it replaces.
    private func fallbackFont(matching descriptor: PDFFontDescriptor, size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        let name = (descriptor.familyName ?? descriptor.baseFontName).lowercased()
        var traits: NSFontDescriptor.SymbolicTraits = []
        if name.contains("bold") || name.contains("black") || name.contains("heavy") {
            traits.insert(.bold)
        }
        if name.contains("italic") || name.contains("oblique") { traits.insert(.italic) }
        guard !traits.isEmpty else { return system }
        let traited = system.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: traited, size: size) ?? system
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
                dragCurrent = normalized(value.location, in: frame.size)
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                guard let start = dragStart else { return }
                editor.commitGesture(
                    from: start,
                    to: normalized(value.location, in: frame.size)
                )
            }
    }

    /// The region under the pointer mid-drag, in page-view coordinates.
    ///
    /// Highlight and redact used to commit blind: nothing was drawn until the
    /// mouse came up, so the size of the mark was a guess. Previewing it makes
    /// the drag legible without changing what gets committed.
    private func dragPreviewRect(in frame: CGRect) -> CGRect? {
        guard toolDrawsDragPreview, let start = dragStart, let current = dragCurrent
        else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    /// Whether the active tool commits a dragged region worth previewing.
    private var toolDrawsDragPreview: Bool {
        switch editor.activeTool {
        case .highlight, .redact, .text: true
        case .select, .signature: false
        }
    }

    @ViewBuilder
    private func dragPreview(_ region: CGRect) -> some View {
        let fill: Color =
            switch editor.activeTool {
            case .highlight: Color(pdfRGBA: PDFHighlightLayer.defaultColor)
            // Held back from full opacity so the content being covered stays
            // readable while it is being framed.
            case .redact: Color(pdfRGBA: PDFRedactionLayer.defaultColor).opacity(0.55)
            default: Color.clear
            }
        Rectangle()
            .fill(fill)
            .overlay {
                Rectangle()
                    .strokeBorder(theme.palette.accentLine, lineWidth: theme.metrics.hairline)
            }
            .frame(width: region.width, height: region.height)
            .position(x: region.midX, y: region.midY)
            .allowsHitTesting(false)
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

extension Color {
    fileprivate init(pdfRGBA color: RGBA) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }
}
