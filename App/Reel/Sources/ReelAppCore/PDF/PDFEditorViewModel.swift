import AIKit
import CoreGraphics
import CoreModel
import Foundation
import Observation
import PDFEngine

public enum PDFEditorTool: String, CaseIterable, Sendable, Identifiable {
    case select
    case text
    case highlight
    case redact

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var help: String {
        switch self {
        case .select: "Select text or edits. Double-click PDF text to edit it in place."
        case .text: "Drag to add a new text box."
        case .highlight: "Drag across an area to highlight it."
        case .redact: "Drag across an area to permanently cover it on export."
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redact: "eye.slash"
        }
    }
}

@MainActor
@Observable
public final class PDFEditorViewModel {
    public private(set) var document: PDFEditDocument
    public private(set) var renderedPage: CGImage?
    public private(set) var thumbnails: [PDFPageID: CGImage] = [:]
    public private(set) var pageAnalysis: PDFPageAnalysis?
    public private(set) var isRendering = false
    public private(set) var isExporting = false
    public private(set) var isRecognizingText = false
    public private(set) var isExportingMarkdown = false
    public private(set) var isResolvingFont = false
    public private(set) var generatedMarkdown: String?
    public private(set) var notice: String?
    public var selectedPageID: PDFPageID
    public var selectedLayerID: PDFLayerID?
    public var selectedSourceTextBlockID: Int?
    public var activeTool: PDFEditorTool = .select
    public var automaticallyResolveMissingFonts: Bool
    /// Current library location for the source PDF.
    public private(set) var sourceURL: URL
    /// Canonical library filename after collision and extension handling.
    public private(set) var sourceDisplayName: String
    public let undoManager = UndoManager()

    private let source: PDFiumDocument
    private let renderer: PDFDocumentRenderer
    private let markdownConverter: PDFMarkdownConverter
    private let toolExecutor: PDFToolExecutor
    private let fontStore: PDFOpenFontStore
    private let persistence: @Sendable (PDFEditDocument) async throws -> Void
    private var renderTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?

    public init(
        document: PDFEditDocument,
        sourceURL: URL,
        source: PDFiumDocument,
        fontStore: PDFOpenFontStore,
        automaticallyResolveMissingFonts: Bool = true,
        persisting: @escaping @Sendable (PDFEditDocument) async throws -> Void
    ) {
        let renderer = PDFDocumentRenderer(
            source: source,
            fontData: { fontStore.cachedData(for: $0) }
        )
        let converter = PDFMarkdownConverter(source: source)
        self.document = document
        self.sourceURL = sourceURL
        self.sourceDisplayName = sourceURL.lastPathComponent
        self.source = source
        self.fontStore = fontStore
        self.automaticallyResolveMissingFonts = automaticallyResolveMissingFonts
        self.renderer = renderer
        self.markdownConverter = converter
        self.toolExecutor = PDFToolExecutor(
            recognizer: { document, pageID in
                let image = try renderer.render(
                    document,
                    pageID: pageID,
                    maxPixelDimension: 2_400
                )
                return try await OnDevicePDFOCR().recognize(image)
            },
            markdownConverter: { document in try converter.convert(document) }
        )
        self.persistence = persisting
        self.selectedPageID = document.pages[0].id
        undoManager.groupsByEvent = false
    }

    public var selectedPage: PDFPage? { document.page(selectedPageID) }

    public var selectedLayer: PDFLayer? {
        guard let selectedLayerID else { return nil }
        return selectedPage?.layers.first { $0.id == selectedLayerID }
    }

    public var editableTextBlocks: [PDFTextBlock] {
        guard let analysis = pageAnalysis else { return [] }
        return analysis.textBlocks.map { block in
            guard let edit = sourceTextEdit(for: block.pageObjectIndex) else { return block }
            return PDFTextBlock(
                pageObjectIndex: block.pageObjectIndex,
                text: edit.text,
                bounds: edit.frame,
                font: edit.font,
                fontSize: edit.fontSize,
                color: edit.color
            )
        }
    }

    public var selectedSourceTextBlock: PDFTextBlock? {
        guard let selectedSourceTextBlockID else { return nil }
        return editableTextBlocks.first { $0.pageObjectIndex == selectedSourceTextBlockID }
    }

    public var selectedPageNumber: Int {
        (document.pages.firstIndex { $0.id == selectedPageID } ?? 0) + 1
    }

    public var fontWarnings: [String] {
        guard let analysis = pageAnalysis, let selectedPage else { return [] }
        let observed = Set(analysis.text)
        return selectedPage.layers.compactMap { layer in
            guard case .text(let text) = layer else { return nil }
            return text.font.warning(for: text.text, observedCharacters: observed)
        }
    }

    public func start() {
        rebuild()
        rebuildThumbnails()
    }

    public func stop() {
        renderTask?.cancel()
        thumbnailTask?.cancel()
        persistenceTask?.cancel()
    }

    /// Rebinds the editor after the library moves its source asset.
    ///
    /// PDFium owns the already-open source bytes, so a filesystem rename does
    /// not require rebuilding the renderer. The edit document title is derived
    /// from the library filename, though, and must be persisted so reopening the
    /// PDF does not restore the old title. This synchronization deliberately
    /// does not register editor undo: the library rename owns that undo action
    /// and will call this method again when it moves the asset back.
    public func relocateSource(to url: URL, displayName: String) {
        let relocatedURL = url.standardizedFileURL
        let didMove = relocatedURL != sourceURL.standardizedFileURL
        if didMove { sourceURL = relocatedURL }
        sourceDisplayName = displayName

        let relocatedTitle = URL(fileURLWithPath: displayName).deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relocatedTitle.isEmpty, relocatedTitle != document.title else { return }

        var candidate = document
        candidate.title = relocatedTitle
        do {
            try candidate.validate()
            document = candidate
            persist()
        } catch {
            notice = "The renamed PDF title could not be saved locally."
        }
    }

    public func selectPage(_ id: PDFPageID) {
        guard document.page(id) != nil else { return }
        selectedPageID = id
        selectedLayerID = nil
        selectedSourceTextBlockID = nil
        rebuild()
    }

    public func perform(_ patch: PDFPatch, actionName: String) throws {
        try perform([patch], actionName: actionName)
    }

    public func perform(_ patches: [PDFPatch], actionName: String) throws {
        guard !patches.isEmpty else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        var candidate = document
        var inverses: [PDFPatch] = []
        for patch in patches { inverses.append(try candidate.apply(patch)) }
        document = candidate
        reconcileSelection()
        registerUndo(Array(inverses.reversed()), actionName: actionName)
        undoManager.setActionName(actionName)
        persist()
        rebuild()
        rebuildThumbnails()
    }

    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    public func rotateSelectedPage() {
        guard var page = selectedPage else { return }
        page.rotation = page.rotation.rotatedClockwise()
        try? perform(.updatePage(page), actionName: "Rotate Page")
    }

    public func moveSelectedPage(by offset: Int) {
        guard let index = document.pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return
        }
        let destination = min(max(index + offset, 0), document.pages.count - 1)
        guard destination != index else { return }
        try? perform(.reorderPage(selectedPageID, to: destination), actionName: "Reorder Page")
    }

    public func addBlankPage() {
        let size = selectedPage?.size ?? PDFPageSize(width: 612, height: 792)
        let page = PDFPage(sourcePageIndex: nil, size: size)
        let index = document.pages.count
        do {
            try perform(.insertPage(page, atIndex: index), actionName: "Add Page")
            selectPage(page.id)
        } catch {
            notice = "The page could not be added."
        }
    }

    public func deleteSelectedPage() {
        guard document.pages.count > 1 else {
            notice = "A PDF must keep at least one page."
            return
        }
        do {
            try perform(.removePage(selectedPageID), actionName: "Delete Page")
        } catch {
            notice = "The page could not be deleted."
        }
    }

    public func commitGesture(from start: CGPoint, to end: CGPoint) {
        let rect = normalizedRect(from: start, to: end)
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        let layer: PDFLayer
        switch activeTool {
        case .select:
            return
        case .text:
            let font =
                pageAnalysis?.fonts.first
                ?? PDFFontDescriptor(postScriptName: "Helvetica")
            layer = .text(PDFTextLayer(text: "Text", frame: rect, font: font, fontSize: 14))
        case .highlight:
            layer = .highlight(PDFHighlightLayer(regions: [rect]))
        case .redact:
            layer = .redaction(PDFRedactionLayer(regions: [rect]))
        }
        do {
            let index = selectedPage?.layers.count ?? 0
            try perform(
                .addLayer(layer, to: selectedPageID, atIndex: index),
                actionName: "Add \(layer.name)"
            )
            selectedLayerID = layer.id
        } catch {
            notice = "The PDF edit could not be added."
        }
    }

    public func selectLayer(_ id: PDFLayerID?) { selectedLayerID = id }

    public func selectSourceTextBlock(_ objectIndex: Int?) {
        selectedSourceTextBlockID = objectIndex
        guard let objectIndex else {
            if case .text(let selectedText) = selectedLayer,
                selectedText.sourceReference != nil
            {
                selectedLayerID = nil
            }
            return
        }
        selectedLayerID =
            selectedPage?.layers.first { layer in
                guard case .text(let text) = layer else { return false }
                return text.sourceReference?.pageObjectIndex == objectIndex
            }?.id
    }

    public func replaceSourceText(objectIndex: Int, with value: String) {
        guard
            editableTextBlocks.contains(where: {
                $0.pageObjectIndex == objectIndex
            })
        else { return }
        if let existing = sourceTextEdit(for: objectIndex) {
            guard existing.text != value else { return }
            var updated = existing
            updated.text = value
            do {
                try perform(
                    .updateLayer(.text(updated), on: selectedPageID),
                    actionName: "Edit PDF Text"
                )
                selectedLayerID = updated.id
                resolveFontIfNeeded(for: updated.id)
            } catch {
                notice = "That PDF text could not be changed."
            }
            return
        }
        guard
            let sourceBlock = pageAnalysis?.textBlocks.first(where: {
                $0.pageObjectIndex == objectIndex
            })
        else { return }
        let edit = PDFTextLayer(
            text: value,
            frame: sourceBlock.bounds,
            font: sourceBlock.font,
            fontSize: sourceBlock.fontSize,
            color: sourceBlock.color,
            sourceReference: PDFSourceTextReference(
                pageObjectIndex: objectIndex,
                originalText: sourceBlock.text,
                originalFontPostScriptName: sourceBlock.font.postScriptName
            )
        )
        do {
            try perform(
                .addLayer(
                    .text(edit),
                    to: selectedPageID,
                    atIndex: selectedPage?.layers.count ?? 0
                ),
                actionName: "Edit PDF Text"
            )
            selectedLayerID = edit.id
            selectedSourceTextBlockID = objectIndex
            resolveFontIfNeeded(for: edit.id)
        } catch {
            notice = "That PDF text could not be changed."
        }
    }

    public func retrySelectedFontResolution() {
        guard let selectedLayerID else { return }
        resolveFontIfNeeded(for: selectedLayerID, force: true)
    }

    public func removeSelectedLayer() {
        guard let selectedLayerID else { return }
        do {
            try perform(
                .removeLayer(selectedLayerID, from: selectedPageID),
                actionName: "Delete PDF Edit"
            )
            self.selectedLayerID = nil
            selectedSourceTextBlockID = nil
        } catch {
            notice = "The PDF edit could not be deleted."
        }
    }

    public func updateSelectedText(_ value: String) {
        guard case .text(var text) = selectedLayer,
            !value.isEmpty || text.sourceReference != nil
        else { return }
        text.text = value
        if let reference = text.sourceReference {
            replaceSourceText(
                objectIndex: reference.pageObjectIndex,
                with: value
            )
        } else {
            try? perform(
                .updateLayer(.text(text), on: selectedPageID),
                actionName: "Edit PDF Text"
            )
        }
    }

    public func export(to url: URL) {
        let document = document
        let renderer = renderer
        isExporting = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try renderer.export(document, to: url)
                }.value
                notice = "Saved \(url.lastPathComponent)."
            } catch {
                notice = "The edited PDF could not be saved."
            }
            isExporting = false
        }
    }

    public func recognizeSelectedPage() {
        runPDFCommand("pdf.ocrPage")
    }

    public func exportMarkdown(to url: URL) {
        let document = document
        let converter = markdownConverter
        isExportingMarkdown = true
        Task {
            do {
                let markdown = try await Task.detached(priority: .userInitiated) {
                    try converter.convert(document)
                }.value
                try Data(markdown.utf8).write(to: url, options: .atomic)
                generatedMarkdown = markdown
                notice = "Saved \(url.lastPathComponent)."
            } catch {
                notice = "The Markdown file could not be saved."
            }
            isExportingMarkdown = false
        }
    }

    public func runPDFCommand(_ id: String) {
        let arguments = defaultArguments(for: id)
        let context = PDFToolExecutionContext(
            document: document,
            selectedPageID: selectedPageID
        )
        if id == "pdf.ocrPage" { isRecognizingText = true }
        if id == "pdf.toMarkdown" { isExportingMarkdown = true }
        Task {
            defer {
                if id == "pdf.ocrPage" { isRecognizingText = false }
                if id == "pdf.toMarkdown" { isExportingMarkdown = false }
            }
            do {
                let result = try await toolExecutor.execute(
                    ToolInvocation(
                        callID: UUID().uuidString,
                        name: id,
                        arguments: arguments
                    ),
                    context: context
                )
                if !result.patches.isEmpty {
                    try perform(
                        result.patches,
                        actionName: CommandRegistry.command(named: id)?.title ?? id
                    )
                }
                if id == "pdf.toMarkdown" { generatedMarkdown = result.value }
                notice = result.message
            } catch {
                notice = "The PDF command could not be completed."
            }
        }
    }

    public func clearNotice() { notice = nil }

    private func rebuild() {
        renderTask?.cancel()
        let document = document
        let pageID = selectedPageID
        guard let page = document.page(pageID) else { return }
        let renderer = renderer
        let source = source
        isRendering = true
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let image = try renderer.render(document, pageID: pageID)
                let analysis = try page.sourcePageIndex.map { try source.analyzePage(at: $0) }
                return (image, analysis)
            }.result
            guard !Task.isCancelled, self.selectedPageID == pageID else { return }
            switch result {
            case .success(let output):
                renderedPage = output.0
                pageAnalysis = output.1
            case .failure:
                notice = "This PDF page could not be rendered."
            }
            isRendering = false
        }
    }

    private func rebuildThumbnails() {
        thumbnailTask?.cancel()
        let document = document
        let renderer = renderer
        thumbnailTask = Task {
            let images = await Task.detached(priority: .utility) {
                var images: [PDFPageID: CGImage] = [:]
                for page in document.pages {
                    if let image = try? renderer.render(
                        document,
                        pageID: page.id,
                        maxPixelDimension: 220
                    ) {
                        images[page.id] = image
                    }
                }
                return images
            }.value
            guard !Task.isCancelled else { return }
            thumbnails = images
        }
    }

    private func persist() {
        persistenceTask?.cancel()
        let document = document
        let persistence = persistence
        persistenceTask = Task {
            do {
                try await persistence(document)
            } catch {
                notice = "The PDF edits could not be saved locally."
            }
        }
    }

    private func registerUndo(_ patches: [PDFPatch], actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            do {
                var candidate = target.document
                var redos: [PDFPatch] = []
                for patch in patches { redos.append(try candidate.apply(patch)) }
                target.document = candidate
                target.reconcileSelection()
                target.registerUndo(Array(redos.reversed()), actionName: actionName)
                target.undoManager.setActionName(actionName)
                target.persist()
                target.rebuild()
                target.rebuildThumbnails()
            } catch {
                target.notice = "The PDF edit could not be undone."
            }
        }
    }

    private func reconcileSelection() {
        if document.page(selectedPageID) == nil {
            selectedPageID = document.pages[0].id
            selectedLayerID = nil
            selectedSourceTextBlockID = nil
        } else if let selectedLayerID,
            selectedPage?.layers.contains(where: { $0.id == selectedLayerID }) != true
        {
            self.selectedLayerID = nil
        }
    }

    private func defaultArguments(for id: String) -> JSONValue {
        let rect: JSONValue = .object([
            "x": .number(0.2), "y": .number(0.2),
            "width": .number(0.36), "height": .number(0.12),
        ])
        switch id {
        case "pdf.addText":
            return .object(["text": .string("Text"), "rect": rect])
        case "pdf.highlight", "pdf.redact":
            return .object(["rect": rect])
        case "pdf.reorderPage":
            let index = document.pages.firstIndex { $0.id == selectedPageID } ?? 0
            let destination = min(index + 1, document.pages.count - 1)
            return .object(["destination": .number(Double(destination))])
        default:
            return .object([:])
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        return CGRect(
            x: min(max(minX, 0), 1),
            y: min(max(minY, 0), 1),
            width: min(max(abs(end.x - start.x), 0), 1 - minX),
            height: min(max(abs(end.y - start.y), 0), 1 - minY)
        )
    }

    private func sourceTextEdit(for objectIndex: Int) -> PDFTextLayer? {
        selectedPage?.layers.compactMap { layer -> PDFTextLayer? in
            guard case .text(let text) = layer,
                text.sourceReference?.pageObjectIndex == objectIndex
            else { return nil }
            return text
        }.first
    }

    private func resolveFontIfNeeded(for layerID: PDFLayerID, force: Bool = false) {
        guard case .text(let text) = selectedPage?.layers.first(where: { $0.id == layerID }),
            let reference = text.sourceReference
        else { return }
        let newCharacters = Set(text.text).subtracting(Set(reference.originalText))
        // Even fonts that report as embedded may only carry the glyph program used by
        // the original text. Asking that object to draw newly introduced characters
        // can otherwise produce .notdef boxes. Prefer a complete verified font whenever
        // an in-place edit expands the original character set.
        let needsGlyphs = !newCharacters.isEmpty
        let unavailableReference =
            !text.font.isEmbedded && !fontStore.exactFontIsInstalled(text.font)
        guard force || needsGlyphs || unavailableReference else { return }
        guard force || automaticallyResolveMissingFonts else {
            notice =
                "This font is unavailable. Enable verified font downloads in Settings or choose Resolve Font."
            return
        }
        isResolvingFont = true
        Task {
            defer { isResolvingFont = false }
            do {
                var resolutionRequest = text.font
                if needsGlyphs {
                    resolutionRequest.isSubset = true
                }
                guard
                    let resolution = try await fontStore.resolve(
                        resolutionRequest,
                        requiredCharacters: Set(text.text),
                        allowsDownload: true
                    )
                else {
                    notice = "No safe font replacement was available."
                    return
                }
                guard resolution.font != text.font,
                    case .text(var current) = selectedPage?.layers.first(where: {
                        $0.id == layerID
                    })
                else {
                    notice = resolution.detail
                    return
                }
                current.font = resolution.font
                try applyAuxiliary(.updateLayer(.text(current), on: selectedPageID))
                notice = resolution.detail
            } catch {
                notice = "Clip could not verify and cache the replacement font."
            }
        }
    }

    /// Font recovery is part of the text edit that requested it, not a second
    /// user operation. Applying it outside the undo stack keeps one Command-Z
    /// sufficient to restore the pre-edit PDF object.
    private func applyAuxiliary(_ patch: PDFPatch) throws {
        var candidate = document
        _ = try candidate.apply(patch)
        document = candidate
        reconcileSelection()
        persist()
        rebuild()
        rebuildThumbnails()
    }
}
