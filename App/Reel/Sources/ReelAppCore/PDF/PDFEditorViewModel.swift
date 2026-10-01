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
    case signature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: "Select"
        case .text: "Add Text"
        case .highlight: "Highlight"
        case .redact: "Redact"
        case .signature: "Signature"
        }
    }

    public var help: String {
        switch self {
        case .select: "Select text or edits. Double-click PDF text to edit it in place."
        case .text: "Click to place text or drag a text box, then type in the inspector."
        case .highlight: "Drag across an area to highlight it."
        case .redact: "Drag over sensitive content. Redaction is permanent in the exported PDF."
        case .signature:
            "Type a name in the inspector, then click the page to place it. Drag to reposition."
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redact: "eye.slash"
        case .signature: "signature"
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
    /// Paragraph structure for the selected page, rebuilt with every analysis.
    ///
    /// Editing waits on this rather than on individual text objects: a click
    /// has to resolve against the finished page so it lands in a paragraph,
    /// not in whichever fragment the content stream happened to split out.
    public private(set) var pageTextIndex = PDFPageTextIndex.empty
    public private(set) var isRendering = false
    public private(set) var isExporting = false
    public private(set) var isRecognizingText = false
    public private(set) var isExportingMarkdown = false
    public private(set) var isResolvingFont = false
    public private(set) var generatedMarkdown: String?
    public private(set) var notice: String?
    /// Last successfully exported edited copy for Command-S during this editor session.
    public private(set) var derivativeURL: URL?
    public var selectedPageID: PDFPageID
    public var selectedLayerID: PDFLayerID?
    public var selectedSourceTextBlockID: Int?
    /// Source objects currently open for in-place editing, withheld from the render.
    public private(set) var editingSourceObjectIDs: Set<Int> = []
    public var activeTool: PDFEditorTool = .select
    /// Name the signature tool will place, shared with its composer.
    public var signatureName = ""
    public var signatureStyle: PDFSignatureStyle = .flowing
    /// Signatures the user has adopted and can stamp again.
    public private(set) var savedSignatures: [SavedSignature] = []
    /// Which saved signature the next click places, if any.
    public var selectedSignatureID: UUID?
    public var automaticallyResolveMissingFonts: Bool
    /// Current library location for the source PDF.
    public private(set) var sourceURL: URL
    /// Canonical library filename after collision and extension handling.
    public private(set) var sourceDisplayName: String
    public let undoManager = UndoManager()

    private let source: PDFiumDocument
    private var findTask: Task<Void, Never>?
    private let renderer: PDFDocumentRenderer
    private let markdownConverter: PDFMarkdownConverter
    private let toolExecutor: PDFToolExecutor
    private let fontStore: PDFOpenFontStore
    private let persistence: @Sendable (PDFEditDocument) async throws -> Void
    private var renderTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private let signatureStore = SavedSignatureStore()

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
        let edits = sourceTextEditsByObjectIndex
        return analysis.textBlocks.map { block in
            guard let edit = edits[block.pageObjectIndex] else { return block }
            return PDFTextBlock(
                pageObjectIndex: block.pageObjectIndex,
                text: edit.text,
                bounds: edit.frame,
                font: edit.font,
                fontSize: edit.fontSize,
                matrixScale: block.matrixScale,
                color: edit.color
            )
        }
    }

    public var selectedSourceTextBlock: PDFTextBlock? {
        guard let selectedSourceTextBlockID else { return nil }
        return editableTextBlocks.first { $0.pageObjectIndex == selectedSourceTextBlockID }
    }

    /// Whether the page has finished indexing and can be edited as text.
    public var isPageIndexed: Bool { !isRendering && !pageTextIndex.isEmpty }

    /// A caret position inside a source text object.
    public struct TextHit: Sendable, Equatable {
        public var pageObjectIndex: Int
        public var characterOffset: Int

        public init(pageObjectIndex: Int, characterOffset: Int) {
            self.pageObjectIndex = pageObjectIndex
            self.characterOffset = characterOffset
        }
    }

    /// Resolves a normalized page point to a caret inside the text under it.
    ///
    /// Editing in place means a click has to name both an object and an offset
    /// within it. The point is first narrowed to the smallest block containing
    /// it, so clicking blank space edits nothing, and the offset is then the
    /// number of that block's glyphs to the left of the click on the nearest
    /// line. Glyphs are compared with a vertical bias so a click lands on the
    /// line it was aimed at rather than a horizontally closer neighbour.
    public func textHit(at point: CGPoint) -> TextHit? {
        guard let analysis = pageAnalysis else { return nil }
        let containing = analysis.textBlocks
            .filter { $0.bounds.insetBy(dx: -0.003, dy: -0.003).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        guard let block = containing else { return nil }

        var offset = 0
        var best: (score: CGFloat, offset: Int)?
        for glyph in analysis.glyphs where glyph.pageObjectIndex == block.pageObjectIndex {
            defer { offset += 1 }
            guard let bounds = glyph.bounds else { continue }
            let verticalGap = max(bounds.minY - point.y, point.y - bounds.maxY, 0)
            let horizontalGap = max(bounds.minX - point.x, point.x - bounds.maxX, 0)
            let score = verticalGap * 4 + horizontalGap
            let landsAfter = point.x > bounds.midX
            let candidate = landsAfter ? offset + 1 : offset
            if score < (best?.score ?? .greatestFiniteMagnitude) {
                best = (score, candidate)
            }
        }
        let text = sourceTextEdit(for: block.pageObjectIndex)?.text ?? block.text
        let resolved = min(best?.offset ?? text.count, text.count)
        return TextHit(pageObjectIndex: block.pageObjectIndex, characterOffset: resolved)
    }

    /// A caret position inside a paragraph's assembled text.
    public struct ParagraphHit: Sendable, Equatable {
        public var paragraphID: Int
        public var characterOffset: Int

        public init(paragraphID: Int, characterOffset: Int) {
            self.paragraphID = paragraphID
            self.characterOffset = characterOffset
        }
    }

    /// Resolves a page point to a caret inside the paragraph under it.
    ///
    /// The object-level hit gives an offset within one text object; converting
    /// it walks that object's spans to find where they sit in the paragraph, so
    /// the caret lands in the continuous text rather than in a fragment.
    public func paragraphHit(at point: CGPoint) -> ParagraphHit? {
        guard let paragraph = pageTextIndex.paragraph(containing: point) else { return nil }
        guard let hit = textHit(at: point) else {
            return ParagraphHit(
                paragraphID: paragraph.id,
                characterOffset: paragraph.text.count
            )
        }
        var consumed = 0
        for placement in paragraph.spanPlacements
        where placement.span.pageObjectIndex == hit.pageObjectIndex {
            if hit.characterOffset <= consumed + placement.length {
                return ParagraphHit(
                    paragraphID: paragraph.id,
                    characterOffset: placement.start + (hit.characterOffset - consumed)
                )
            }
            consumed += placement.length
        }
        return ParagraphHit(paragraphID: paragraph.id, characterOffset: paragraph.text.count)
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
        savedSignatures = signatureStore.load()
        selectedSignatureID = savedSignatures.first?.id
        rebuild()
        rebuildThumbnails()
    }

    public func stop() {
        renderTask?.cancel()
        thumbnailTask?.cancel()
        // Take the pending autosave now rather than losing it: the debounce
        // exists to batch typing, not to drop the last edit on close.
        if autosaveTask != nil {
            autosaveTask?.cancel()
            autosaveTask = nil
            saveToLastDerivative()
        }
        flushPersistence()
    }

    /// Lets the pending local write finish as the editor goes away.
    ///
    /// `persist()` writes asynchronously, so cancelling its task here raced the
    /// write and silently dropped whatever had just been edited: closing a PDF
    /// shortly after a change reopened it with the change missing. The write is
    /// detached so closing the editor cannot cancel it.
    private func flushPersistence() {
        persistenceTask?.cancel()
        persistenceTask = nil
        let document = document
        let persistence = persistence
        Task.detached(priority: .userInitiated) {
            try? await persistence(document)
        }
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
        var candidate = document
        var inverses: [PDFPatch] = []
        for patch in patches { inverses.append(try candidate.apply(patch)) }
        // Opening a block and closing it unchanged is not an edit. Committing
        // it anyway wrote the file, pushed an undo step that restores what is
        // already on screen, and re-rendered every thumbnail.
        guard candidate != document else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
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

    public func duplicateSelectedPage() {
        guard let page = selectedPage,
            let index = document.pages.firstIndex(where: { $0.id == page.id })
        else { return }
        let duplicate = PDFPage(
            sourcePageIndex: page.sourcePageIndex,
            size: page.size,
            rotation: page.rotation,
            layers: page.layers.map(Self.duplicatedLayer),
            ocrText: page.ocrText
        )
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        do {
            try perform(
                .insertPage(duplicate, atIndex: index + 1),
                actionName: "Duplicate Page"
            )
            selectPage(duplicate.id)
            registerPageSelectionUndo(
                selecting: page.id,
                inversePageID: duplicate.id,
                actionName: "Duplicate Page"
            )
            undoManager.setActionName("Duplicate Page")
        } catch {
            notice = "The page could not be duplicated."
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
        // The drag is in display space; marks are stored unrotated so they
        // stay on the same content if the page is rotated later.
        let stored = (selectedPage?.rotation ?? .degrees0).storedRect(fromDisplay: rect)
        let layer: PDFLayer
        switch activeTool {
        case .select:
            return
        // A signature is placed by clicking, not by dragging out a box: its
        // size comes from the name, so a dragged rectangle would distort it.
        case .signature:
            return
        case .text:
            _ = addText(in: rect)
            return
        case .highlight:
            layer = .highlight(PDFHighlightLayer(regions: [stored]))
        case .redact:
            layer = .redaction(PDFRedactionLayer(regions: [stored]))
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

    /// Places a useful default text box for either a click or a drag.
    @discardableResult
    public func addText(at point: CGPoint) -> PDFLayerID? {
        let width = 0.32
        let height = 0.08
        let origin = CGPoint(
            x: min(max(point.x - width / 2, 0), 1 - width),
            y: min(max(point.y - height / 2, 0), 1 - height)
        )
        return addText(in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
    }

    /// Keeps the current name and style for reuse in any document.
    public func adoptSignature() {
        let trimmed = signatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = "Type a name to save a signature."
            return
        }
        let existing = savedSignatures.first {
            $0.name == trimmed && $0.style == signatureStyle
        }
        if let existing {
            selectedSignatureID = existing.id
            return
        }
        let adopted = SavedSignature(name: trimmed, style: signatureStyle)
        savedSignatures.append(adopted)
        selectedSignatureID = adopted.id
        signatureStore.save(savedSignatures)
    }

    public func removeSignature(_ id: UUID) {
        savedSignatures.removeAll { $0.id == id }
        if selectedSignatureID == id { selectedSignatureID = savedSignatures.first?.id }
        signatureStore.save(savedSignatures)
    }

    /// Makes a saved signature the one the next click places.
    public func useSignature(_ id: UUID) {
        guard let signature = savedSignatures.first(where: { $0.id == id }) else { return }
        selectedSignatureID = id
        signatureName = signature.name
        signatureStyle = signature.style
        activeTool = .signature
    }

    /// Places a typed signature, sized to the name it spells.
    ///
    /// A signature is a text layer in a script face rather than a pasted image,
    /// so it stays vector in the page and can be re-typed instead of redrawn.
    @discardableResult
    public func addSignature(
        _ name: String,
        style: PDFSignatureStyle,
        at point: CGPoint
    ) -> PDFLayerID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = "Type a name to sign with."
            return nil
        }
        let pageSize = selectedPage?.size ?? PDFPageSize(width: 612, height: 792)
        // Measure rather than estimate. Script faces vary enormously in width —
        // Zapfino runs several times wider than Snell for the same string — and
        // a frame too small for the text makes CoreText draw nothing at all
        // rather than overflow, so the signature simply never appeared.
        let pointSize = pageSize.height * 0.045
        let measured = style.measure(trimmed, atPointSize: pointSize)
        let width = min(max(measured.width / pageSize.width, 0.08), 0.6)
        let height = min(max(measured.height / pageSize.height, 0.02), 0.25)
        let origin = CGPoint(
            x: min(max(point.x - width / 2, 0), max(1 - width, 0)),
            y: min(max(point.y - height / 2, 0), max(1 - height, 0))
        )
        let signature = PDFTextLayer(
            text: trimmed,
            frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            font: style.fontDescriptor,
            fontSize: pointSize
        )
        do {
            try perform(
                .addLayer(
                    .text(signature),
                    to: selectedPageID,
                    atIndex: selectedPage?.layers.count ?? 0
                ),
                actionName: "Add Signature"
            )
            selectedLayerID = signature.id
            return signature.id
        } catch {
            notice = "The signature could not be added."
            return nil
        }
    }

    /// Moves a placed layer so its frame origin lands at `origin`.
    public func moveLayer(_ id: PDFLayerID, to origin: CGPoint) {
        guard let page = selectedPage,
            let layer = page.layers.first(where: { $0.id == id })
        else { return }
        guard case .text(var text) = layer, text.sourceReference == nil else { return }
        let clamped = CGPoint(
            x: min(max(origin.x, 0), max(1 - text.frame.width, 0)),
            y: min(max(origin.y, 0), max(1 - text.frame.height, 0))
        )
        guard clamped != text.frame.origin else { return }
        text.frame.origin = clamped
        do {
            try perform(.updateLayer(.text(text), on: selectedPageID), actionName: "Move")
        } catch {
            notice = "That edit could not be moved."
        }
    }

    @discardableResult
    private func addText(in rect: CGRect) -> PDFLayerID? {
        let font = pageAnalysis?.fonts.first ?? PDFFontDescriptor(postScriptName: "Helvetica")
        let text = PDFTextLayer(text: "Text", frame: rect, font: font, fontSize: 14)
        do {
            try perform(
                .addLayer(
                    .text(text),
                    to: selectedPageID,
                    atIndex: selectedPage?.layers.count ?? 0
                ),
                actionName: "Add Text"
            )
            selectedLayerID = text.id
            notice = "Text box added. Type in the inspector to edit it."
            return text.id
        } catch {
            notice = "The text box could not be added."
            return nil
        }
    }

    public func selectLayer(_ id: PDFLayerID?) {
        selectedLayerID = id
        selectedMarkRegion = nil
    }

    /// Which region of the selected mark was clicked, when it holds several.
    public private(set) var selectedMarkRegion: Int?

    public func selectMark(_ hit: PDFMarkHit) {
        selectedLayerID = hit.layerID
        selectedMarkRegion = hit.regionIndex
    }

    /// The regions of the selected mark, for the view to outline.
    public var selectedMarkRegions: [CGRect] {
        guard let selectedLayer else { return [] }
        let regions = PDFMarkHitTest.regions(of: selectedLayer)
        guard let index = selectedMarkRegion, regions.indices.contains(index) else {
            return regions
        }
        return [regions[index]]
    }

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

    /// Applies edited paragraph text back to the objects it was assembled from.
    ///
    /// The edit is narrowed to the region between the unchanged prefix and
    /// suffix, then attributed to the spans that region covers. A change inside
    /// one span rewrites only that object, so a bold phrase beside it keeps its
    /// own object, face and position — which is what stops a paragraph behaving
    /// like a row of separate boxes. Every object changes in one patch, so the
    /// whole paragraph edit is a single undo step.
    public func replaceParagraphText(_ paragraph: PDFTextParagraph, with edited: String) {
        let placements = paragraph.spanPlacements
        let original = Array(paragraph.text)
        let updated = Array(edited)
        guard original != updated else { return }

        var prefix = 0
        while prefix < original.count, prefix < updated.count, original[prefix] == updated[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < original.count - prefix, suffix < updated.count - prefix,
            original[original.count - 1 - suffix] == updated[updated.count - 1 - suffix]
        {
            suffix += 1
        }
        let changedStart = prefix
        let changedEnd = original.count - suffix
        let replacement = String(updated[prefix..<(updated.count - suffix)])

        // A pure insertion covers no span, so it is attributed to the span it
        // was typed into rather than dropped.
        var affected = placements.filter { $0.end > changedStart && $0.start < changedEnd }
        if affected.isEmpty {
            let host =
                placements.last { $0.start <= changedStart && changedStart <= $0.end }
                ?? placements.first
            affected = host.map { [$0] } ?? []
        }
        guard let first = affected.first else { return }

        var rebuilt: [Int: String] = [:]
        for placement in placements {
            let object = placement.span.pageObjectIndex
            rebuilt[object, default: ""] += text(
                for: placement,
                in: affected,
                first: first,
                changedStart: changedStart,
                changedEnd: changedEnd,
                replacement: replacement
            )
        }

        var patches: [PDFPatch] = []
        for (objectIndex, value) in rebuilt.sorted(by: { $0.key < $1.key }) {
            // A PDF text object holds one run and cannot carry a line break.
            // The paragraph's own breaks belong to no span, so one only reaches
            // here when an edit spanned a boundary; it becomes a space.
            let flattened = value.replacingOccurrences(of: "\n", with: " ")
            if let patch = sourceTextPatch(objectIndex: objectIndex, with: flattened) {
                patches.append(patch)
            }
        }
        guard !patches.isEmpty else { return }
        do {
            try perform(patches, actionName: "Edit PDF Text")
        } catch {
            notice = "That PDF text could not be changed."
        }
    }

    /// The text one span contributes after the edit.
    private func text(
        for placement: PDFTextParagraph.SpanPlacement,
        in affected: [PDFTextParagraph.SpanPlacement],
        first: PDFTextParagraph.SpanPlacement,
        changedStart: Int,
        changedEnd: Int,
        replacement: String
    ) -> String {
        guard affected.contains(where: { $0.start == placement.start }) else {
            return placement.span.text
        }
        let characters = Array(placement.span.text)
        let localStart = min(max(changedStart - placement.start, 0), characters.count)
        let localEnd = min(max(changedEnd - placement.start, 0), characters.count)
        let head = String(characters[0..<localStart])
        let tail = String(characters[localEnd...])
        // The replacement lands whole in the first covered span; later spans
        // keep only whatever survived past the edit.
        return placement.start == first.start ? head + replacement + tail : tail
    }

    /// The patch that sets one source object's text, creating its edit layer on
    /// first use.
    private func sourceTextPatch(objectIndex: Int, with value: String) -> PDFPatch? {
        if let existing = sourceTextEdit(for: objectIndex) {
            guard existing.text != value else { return nil }
            var updated = existing
            updated.text = value
            return .updateLayer(.text(updated), on: selectedPageID)
        }
        guard
            let block = pageAnalysis?.textBlocks.first(where: {
                $0.pageObjectIndex == objectIndex
            }),
            block.text != value
        else { return nil }
        let edit = PDFTextLayer(
            text: value,
            frame: block.bounds,
            font: block.font,
            fontSize: block.fontSize,
            color: block.color,
            sourceReference: PDFSourceTextReference(
                pageObjectIndex: objectIndex,
                originalText: block.text,
                originalFontPostScriptName: block.font.postScriptName,
                originalFrame: block.bounds
            )
        )
        return .addLayer(
            .text(edit),
            to: selectedPageID,
            atIndex: selectedPage?.layers.count ?? 0
        )
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
                originalFontPostScriptName: sourceBlock.font.postScriptName,
                originalFrame: sourceBlock.bounds
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

    /// A patch that drops just the clicked region, or nil when the whole layer
    /// should go — a mark with one region left, or anything that is not a mark.
    private func removalOfSelectedRegion() -> PDFPatch? {
        guard let selectedLayerID, let index = selectedMarkRegion, var page = selectedPage,
            let position = page.layers.firstIndex(where: { $0.id == selectedLayerID })
        else { return nil }

        switch page.layers[position] {
        case .redaction(var redaction) where redaction.regions.count > 1:
            guard redaction.regions.indices.contains(index) else { return nil }
            redaction.regions.remove(at: index)
            page.layers[position] = .redaction(redaction)
        case .highlight(var highlight) where highlight.regions.count > 1:
            guard highlight.regions.indices.contains(index) else { return nil }
            highlight.regions.remove(at: index)
            page.layers[position] = .highlight(highlight)
        case .redaction, .highlight, .text:
            return nil
        }
        return .updatePage(page)
    }

    public func removeSelectedLayer() {
        guard let selectedLayerID else { return }
        // A mark holding several regions loses only the one that was clicked.
        // Batch redactions made before each match became its own layer are a
        // single layer carrying every match on the page, and removing the layer
        // to undo one of them took back all the others with it.
        if let patch = removalOfSelectedRegion() {
            do {
                try perform(patch, actionName: "Delete Redaction")
                selectedMarkRegion = nil
            } catch {
                notice = "The PDF edit could not be deleted."
            }
            return
        }
        do {
            try perform(
                .removeLayer(selectedLayerID, from: selectedPageID),
                actionName: "Delete PDF Edit"
            )
            self.selectedLayerID = nil
            selectedMarkRegion = nil
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

    /// Exports an edited derivative without ever replacing the immutable source asset.
    @discardableResult
    public func export(to url: URL) -> Bool {
        guard !isExporting else { return true }
        guard !Self.refersToSameFile(url, sourceURL) else {
            notice =
                "The original PDF is immutable. Choose a different filename to save an edited copy."
            return false
        }
        let document = document
        let renderer = renderer
        isExporting = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try renderer.export(document, to: url)
                }.value
                derivativeURL = url.standardizedFileURL
                notice = "Saved \(url.lastPathComponent)."
            } catch {
                notice = "The edited PDF could not be saved."
            }
            isExporting = false
        }
        return true
    }

    /// Handles Command-S.
    ///
    /// The source PDF is immutable, so there is nothing to write back into and
    /// every edit is already persisted to the library overlay as it is made.
    /// Save therefore confirms that, and refreshes an exported copy when one
    /// has already been chosen. It deliberately never opens a file picker:
    /// choosing a destination is Save As, on Shift-Command-S.
    /// Writes the edits into the edited copy shortly after typing stops.
    ///
    /// Only ever to a destination already chosen with Save As. The source PDF is
    /// never written: ADR-0013 makes an in-place save destructive — it flattens
    /// the layers and discards the non-destructive model — and that is not
    /// something to do on a timer while someone is still editing. Until a
    /// destination exists this does nothing, and Save As remains the one
    /// deliberate step.
    private func scheduleAutosave() {
        guard derivativeURL != nil, !isExporting else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            // Long enough that a burst of typing is one write rather than one
            // per keystroke, short enough to be gone before anyone quits.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, derivativeURL != nil else { return }
            saveToLastDerivative()
        }
    }

    public func saveEdits() {
        persist()
        guard !saveToLastDerivative() else { return }
        notice = "Edits saved. Use Save As to export a copy."
    }

    /// Saves to the last successful edited copy. Returning false asks the view
    /// to present Save As because no safe in-session destination is available.
    @discardableResult
    public func saveToLastDerivative() -> Bool {
        guard !isExporting else { return true }
        guard let derivativeURL,
            !Self.refersToSameFile(derivativeURL, sourceURL)
        else {
            self.derivativeURL = nil
            return false
        }
        return export(to: derivativeURL)
    }

    /// Compares canonical paths first, then volume-stable file identifiers so
    /// symlinks and hard links cannot bypass the source-asset protection.
    static func refersToSameFile(_ candidate: URL, _ source: URL) -> Bool {
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalSource = source.standardizedFileURL.resolvingSymlinksInPath()
        if canonicalCandidate == canonicalSource { return true }

        guard
            let candidateIdentifier = try? canonicalCandidate.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier,
            let sourceIdentifier = try? canonicalSource.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier
        else { return false }
        return (candidateIdentifier as? NSObject)?.isEqual(sourceIdentifier) == true
    }

    private static func duplicatedLayer(_ layer: PDFLayer) -> PDFLayer {
        switch layer {
        case .text(var text):
            text.id = .generate()
            return .text(text)
        case .highlight(var highlight):
            highlight.id = .generate()
            return .highlight(highlight)
        case .redaction(var redaction):
            redaction.id = .generate()
            return .redaction(redaction)
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

    // MARK: - Find

    public var findQuery: String = ""
    public private(set) var findMatches: [PDFTextMatch] = []
    public private(set) var findIndex: Int = 0
    public private(set) var isFinding = false
    public var showsFindBar = false {
        didSet {
            guard !showsFindBar else { return }
            findQuery = ""
            findMatches = []
            findIndex = 0
        }
    }
    /// Bumped whenever Find is invoked, so the field can take focus again even
    /// when the bar was already open and `showsFindBar` therefore did not change.
    public private(set) var findBarFocusRequests = 0

    public func presentFindBar() {
        showsFindBar = true
        findBarFocusRequests &+= 1
    }

    /// The match currently stepped to, for the page view to highlight.
    public var currentFindMatch: PDFTextMatch? {
        guard findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex]
    }

    /// Matches on the page being shown, so the highlight follows the page.
    public var findMatchesOnSelectedPage: [PDFTextMatch] {
        findMatches.filter { $0.pageID == selectedPageID }
    }

    public func runFind() {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        findTask?.cancel()
        guard !query.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }
        isFinding = true
        let locate = textLocator()
        let document = document
        findTask = Task {
            defer { isFinding = false }
            let found = (try? await locate(document, query, nil)) ?? []
            guard !Task.isCancelled else { return }
            findMatches = found
            findIndex = 0
            // Follow the first hit, which is usually on another page: a find
            // that reports matches while showing none of them reads as broken.
            if let first = found.first, first.pageID != selectedPageID {
                selectPage(first.pageID)
            }
        }
    }

    public func stepFind(by offset: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + offset + findMatches.count) % findMatches.count
        let match = findMatches[findIndex]
        if match.pageID != selectedPageID { selectPage(match.pageID) }
    }

    /// Redacts every current match, as one undo entry.
    public func redactFindMatches() {
        guard !findMatches.isEmpty else { return }
        let byPage = Dictionary(grouping: findMatches, by: \.pageID)
        var patches: [PDFPatch] = []
        for (pageID, matches) in byPage.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard var page = document.page(pageID) else { continue }
            // One layer per match, not one layer holding every match. A layer is
            // the unit of selection and deletion, so batching them made the
            // whole run all-or-nothing: a redaction that landed somewhere
            // unwanted could only be removed by taking back the others too.
            // They are still appended in one patch, so the run remains a single
            // undo.
            for match in matches {
                page.layers.append(.redaction(PDFRedactionLayer(regions: [match.rect])))
            }
            patches.append(.updatePage(page))
        }
        guard !patches.isEmpty else { return }
        do {
            try perform(patches, actionName: "Redact Matches")
            notice = "Redacted \(findMatches.count) match\(findMatches.count == 1 ? "" : "es")."
        } catch {
            notice = "Those matches could not be redacted."
        }
    }

    /// Searches the document's glyphs for a string.
    ///
    /// Analyses each page in turn rather than reusing the rendered page's
    /// analysis, because only the selected page has one and a request to redact
    /// a name means every page it appears on, not the one that happens to be
    /// open. Runs detached: analysis is PDFium work and has no business on the
    /// main actor.
    nonisolated func textLocator() -> PDFTextLocating {
        let source = source
        let fontStore = fontStore
        return { document, query, restrictedTo in
            let pages = document.pages.filter { restrictedTo == nil || $0.id == restrictedTo }
            return try await Task.detached(priority: .userInitiated) {
                var matches: [PDFTextMatch] = []
                for page in pages {
                    // Only layers that stand on their own. A layer carrying a
                    // sourceReference replaces a real page object, and the
                    // analysis below is asked to apply it — so searching both
                    // found the same word twice and drew two highlights, one
                    // from each measurement.
                    for layer in page.layers {
                        guard case .text(let text) = layer, text.sourceReference == nil else {
                            continue
                        }
                        for found in PDFLayerTextSearch.matches(of: query, in: text) {
                            matches.append(
                                PDFTextMatch(
                                    pageID: page.id, rect: found.rect, snippet: found.snippet))
                        }
                    }
                    guard let index = page.sourcePageIndex else { continue }
                    let edits = page.layers.compactMap { layer -> PDFTextLayer? in
                        guard case .text(let text) = layer, text.sourceReference != nil else {
                            return nil
                        }
                        return text
                    }
                    guard
                        let analysis = try? source.analyzePage(
                            at: index,
                            applying: edits,
                            fontData: { fontStore.cachedData(for: $0) }
                        )
                    else { continue }
                    for found in PDFGlyphTextSearch.matches(of: query, in: analysis.glyphs) {
                        matches.append(
                            PDFTextMatch(pageID: page.id, rect: found.rect, snippet: found.snippet))
                    }
                }
                return matches
            }.value
        }
    }

    /// Runs an assistant-issued PDF command and reports what it did.
    ///
    /// Goes through `perform`, the same mutation path the UI uses, so an edit
    /// the assistant makes is one undo entry and reaches the document the same
    /// way a click would.
    public func runAssistantCommand(_ invocation: ToolInvocation) async throws -> String {
        let result = try await toolExecutor.execute(
            invocation,
            context: PDFToolExecutionContext(
                document: document,
                selectedPageID: selectedPageID,
                locatingText: textLocator()
            )
        )
        if !result.patches.isEmpty {
            try perform(
                result.patches,
                actionName: CommandRegistry.command(named: invocation.name)?.title
                    ?? invocation.name
            )
        }
        if invocation.name == "pdf.toMarkdown" { generatedMarkdown = result.value }
        return result.message
    }

    public func runPDFCommand(_ id: String) {
        let arguments = defaultArguments(for: id)
        let context = PDFToolExecutionContext(
            document: document,
            selectedPageID: selectedPageID,
            locatingText: textLocator()
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

    /// Opens or closes in-place editing for a source text object.
    ///
    /// The page is re-rasterized without the object so its original glyphs are
    /// absent while it is edited, rather than obscured by the editor drawn over
    /// them. Passing nil restores the full page.
    public func setEditingSourceObjects(_ objectIndexes: Set<Int>) {
        guard editingSourceObjectIDs != objectIndexes else { return }
        editingSourceObjectIDs = objectIndexes
        rebuild()
    }

    private func rebuild() {
        renderTask?.cancel()
        let document = document
        let pageID = selectedPageID
        guard let page = document.page(pageID) else { return }
        let renderer = renderer
        let source = source
        let suppressed = editingSourceObjectIDs
        // Analyse the page as it is drawn. Reading the untouched source instead
        // left the paragraph model one edit behind what was on screen.
        let appliedEdits = page.layers.compactMap { layer -> PDFTextLayer? in
            guard case .text(let text) = layer, text.sourceReference != nil else { return nil }
            return text
        }
        let fontStore = fontStore
        isRendering = true
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let image = try renderer.render(
                    document,
                    pageID: pageID,
                    suppressedObjectIndexes: suppressed
                )
                let analysis = try page.sourcePageIndex.map {
                    try source.analyzePage(
                        at: $0,
                        applying: appliedEdits,
                        fontData: { fontStore.cachedData(for: $0) }
                    )
                }
                return (image, analysis)
            }.result
            guard !Task.isCancelled, self.selectedPageID == pageID else { return }
            switch result {
            case .success(let output):
                renderedPage = output.0
                pageAnalysis = output.1
                pageTextIndex = output.1.map(PDFPageTextIndex.build(from:)) ?? .empty
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
        scheduleAutosave()
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

    private func registerPageSelectionUndo(
        selecting pageID: PDFPageID,
        inversePageID: PDFPageID,
        actionName: String
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            guard target.document.page(pageID) != nil else { return }
            target.selectedPageID = pageID
            target.selectedLayerID = nil
            target.selectedSourceTextBlockID = nil
            target.rebuild()
            target.registerPageSelectionUndo(
                selecting: inversePageID,
                inversePageID: pageID,
                actionName: actionName
            )
            target.undoManager.setActionName(actionName)
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

    /// Source text edits on the selected page, keyed by the source object each replaces.
    ///
    /// `editableTextBlocks` is read from a SwiftUI body on every invalidation
    /// while the select tool is active. Indexing the page's layers once keeps
    /// that O(blocks + layers); rescanning every layer per block made a
    /// text-heavy page quadratic and allocated an array per block.
    private var sourceTextEditsByObjectIndex: [Int: PDFTextLayer] {
        guard let selectedPage else { return [:] }
        return selectedPage.layers.reduce(into: [:]) { index, layer in
            guard case .text(let text) = layer,
                let reference = text.sourceReference,
                index[reference.pageObjectIndex] == nil
            else { return }
            index[reference.pageObjectIndex] = text
        }
    }

    private func sourceTextEdit(for objectIndex: Int) -> PDFTextLayer? {
        selectedPage?.layers.lazy.compactMap { layer -> PDFTextLayer? in
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
                notice = "clipx could not verify and cache the replacement font."
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
