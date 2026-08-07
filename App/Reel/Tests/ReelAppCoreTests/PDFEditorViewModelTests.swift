import CaptureKit
import CoreGraphics
import CoreModel
import CoreText
import Foundation
import PDFEngine
import Testing

@testable import ReelAppCore

// PDFium rendering and Core Graphics font setup are process-global, so running
// these renderer-heavy journeys concurrently makes their async publications
// contend on slower hosted macOS runners.
@Suite("PDF editor mutation path", .serialized)
struct PDFEditorViewModelTests {
    @Test("Source text is selected and replaced through the undoable model")
    @MainActor
    func directTextEditing() async throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-text-fixture"),
            title: "Text Fixture"
        )
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/text-fixture.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-font-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            automaticallyResolveMissingFonts: false,
            persisting: { _ in }
        )
        editor.start()
        try await waitUntil { !editor.editableTextBlocks.isEmpty }
        let before = editor.document
        let block = try #require(editor.editableTextBlocks.first)

        editor.selectSourceTextBlock(block.pageObjectIndex)
        editor.replaceSourceText(objectIndex: block.pageObjectIndex, with: "PDF text changed")

        let layer = try #require(editor.selectedLayer)
        guard case .text(let text) = layer else {
            Issue.record("Expected a source text edit")
            return
        }
        #expect(text.text == "PDF text changed")
        #expect(text.sourceReference?.pageObjectIndex == block.pageObjectIndex)
        editor.undo()
        #expect(editor.document == before)
        editor.stop()
    }

    @Test("Page and layer edits persist and undo exactly")
    @MainActor
    func editsPersistAndUndo() async throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-fixture"),
            title: "Fixture"
        )
        let recorder = PDFPersistenceRecorder()
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-font-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            persisting: { document in await recorder.save(document) }
        )
        editor.start()
        try await waitUntil { editor.renderedPage != nil }

        let before = editor.document
        editor.rotateSelectedPage()
        #expect(editor.selectedPage?.rotation == .degrees90)
        editor.undo()
        #expect(editor.document == before)

        editor.activeTool = .redact
        editor.commitGesture(
            from: CGPoint(x: 0.1, y: 0.1),
            to: CGPoint(x: 0.4, y: 0.3)
        )
        #expect(editor.selectedPage?.layers.count == 1)
        editor.undo()
        #expect(editor.document == before)

        editor.recognizeSelectedPage()
        try await waitUntil { editor.selectedPage?.ocrText != nil }
        editor.runPDFCommand("pdf.toMarkdown")
        try await waitUntil { editor.generatedMarkdown != nil }
        #expect(editor.generatedMarkdown?.contains("<!-- Page 1 -->") == true)

        try await waitUntil { await recorder.count >= 2 }
        editor.stop()
    }

    @Test("Add Text click placement and redaction create editable undoable layers")
    @MainActor
    func addTextAndRedactionTools() throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-tool-fixture"),
            title: "Tool Fixture"
        )
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/pdf-tool-fixture.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-font-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            persisting: { _ in }
        )

        let textID = try #require(editor.addText(at: CGPoint(x: 0.98, y: 0.98)))
        guard case .text(let text) = editor.selectedLayer else {
            Issue.record("Expected Add Text to select a text layer")
            return
        }
        #expect(text.id == textID)
        #expect(text.frame.maxX <= 1)
        #expect(text.frame.maxY <= 1)
        editor.updateSelectedText("Editable text")
        guard case .text(let updatedText) = editor.selectedLayer else {
            Issue.record("Expected editable text layer")
            return
        }
        #expect(updatedText.text == "Editable text")

        editor.activeTool = .redact
        editor.commitGesture(
            from: CGPoint(x: 0.1, y: 0.2),
            to: CGPoint(x: 0.45, y: 0.35)
        )
        guard case .redaction(let redaction) = editor.selectedLayer else {
            Issue.record("Expected the Redact tool to select a redaction layer")
            return
        }
        let region = try #require(redaction.regions.first)
        #expect(abs(region.minX - 0.1) < 0.000_001)
        #expect(abs(region.minY - 0.2) < 0.000_001)
        #expect(abs(region.width - 0.35) < 0.000_001)
        #expect(abs(region.height - 0.15) < 0.000_001)

        editor.undo()
        #expect(editor.selectedPage?.layers.count == 1)
        editor.redo()
        #expect(editor.selectedPage?.layers.count == 2)
    }

    @Test("Duplicating a page deep-copies edits and participates in undo and redo")
    @MainActor
    func duplicatePageDeepCopiesLayers() throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-duplicate-fixture"),
            title: "Duplicate Fixture"
        )
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/pdf-duplicate-fixture.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-font-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            persisting: { _ in }
        )
        _ = editor.addText(at: CGPoint(x: 0.4, y: 0.4))
        editor.activeTool = .redact
        editor.commitGesture(
            from: CGPoint(x: 0.2, y: 0.2),
            to: CGPoint(x: 0.4, y: 0.3)
        )
        let before = editor.document
        let original = try #require(editor.selectedPage)
        let originalLayerIDs = Set(original.layers.map(\.id))

        editor.duplicateSelectedPage()

        #expect(editor.document.pages.count == before.pages.count + 1)
        let duplicate = try #require(editor.selectedPage)
        #expect(duplicate.id != original.id)
        #expect(duplicate.sourcePageIndex == original.sourcePageIndex)
        #expect(duplicate.rotation == original.rotation)
        #expect(duplicate.ocrText == original.ocrText)
        #expect(duplicate.layers.count == original.layers.count)
        #expect(Set(duplicate.layers.map(\.id)).isDisjoint(with: originalLayerIDs))

        editor.undo()
        #expect(editor.document == before)
        #expect(editor.selectedPageID == original.id)
        editor.redo()
        #expect(editor.document.pages.count == before.pages.count + 1)
        #expect(editor.document.pages.contains(where: { $0.id == duplicate.id }))
        #expect(editor.selectedPageID == duplicate.id)
    }

    @Test("Relocating the source updates and persists the filename-derived title")
    @MainActor
    func relocateSource() async throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "relocated-pdf-fixture"),
            title: "Original Name"
        )
        let recorder = PDFPersistenceRecorder()
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/Original Name.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-font-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            persisting: { document in await recorder.save(document) }
        )
        let relocated = URL(fileURLWithPath: "/tmp/Renamed Notes.pdf")

        editor.relocateSource(to: relocated, displayName: "Renamed Notes.pdf")

        #expect(editor.sourceURL == relocated.standardizedFileURL)
        #expect(editor.sourceDisplayName == "Renamed Notes.pdf")
        #expect(editor.document.title == "Renamed Notes")
        #expect(!editor.undoManager.canUndo)
        try await waitUntil { await recorder.last?.title == "Renamed Notes" }
        editor.stop()
    }

    @Test("Export refuses the immutable source through canonical paths and file aliases")
    @MainActor
    func exportRejectsSourceAliases() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-pdf-source-guard-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let sourceURL = fixtureRoot.appendingPathComponent("Original.pdf")
        let sourceData = try fixturePDF()
        try sourceData.write(to: sourceURL, options: .atomic)
        let source = try PDFiumDocument(data: sourceData)
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-source-guard"),
            title: "Original"
        )
        let editor = PDFEditorViewModel(
            document: document,
            sourceURL: sourceURL,
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: fixtureRoot.appendingPathComponent("Fonts", isDirectory: true)
            ),
            persisting: { _ in }
        )

        let dottedSourceURL = fixtureRoot.appendingPathComponent("Folder/../Original.pdf")
        #expect(!editor.export(to: dottedSourceURL))
        #expect(
            editor.notice
                == "The original PDF is immutable. Choose a different filename to save an edited copy."
        )
        #expect(!editor.isExporting)

        let aliasURL = fixtureRoot.appendingPathComponent("Original Alias.pdf")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: sourceURL)
        #expect(!editor.export(to: aliasURL))

        let hardLinkURL = fixtureRoot.appendingPathComponent("Original Hard Link.pdf")
        try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)
        #expect(!editor.export(to: hardLinkURL))
        #expect(try Data(contentsOf: sourceURL) == sourceData)
    }

    @Test("Command save reuses only the last successful derivative destination")
    @MainActor
    func saveReusesDerivativeDestination() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-pdf-derivative-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let sourceData = try fixturePDF()
        let sourceURL = fixtureRoot.appendingPathComponent("Original.pdf")
        try sourceData.write(to: sourceURL, options: .atomic)
        let source = try PDFiumDocument(data: sourceData)
        let editor = PDFEditorViewModel(
            document: try source.makeEditDocument(
                sourceAssetID: AssetID(rawValue: "pdf-derivative"),
                title: "Derivative"
            ),
            sourceURL: sourceURL,
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: fixtureRoot.appendingPathComponent("Fonts", isDirectory: true)
            ),
            persisting: { _ in }
        )

        #expect(!editor.saveToLastDerivative())
        let derivativeURL = fixtureRoot.appendingPathComponent("Edited.pdf")
        #expect(editor.export(to: derivativeURL))
        try await waitUntil { !editor.isExporting }
        #expect(editor.derivativeURL == derivativeURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: derivativeURL.path))

        editor.rotateSelectedPage()
        #expect(editor.saveToLastDerivative())
        try await waitUntil { !editor.isExporting }
        #expect(editor.derivativeURL == derivativeURL.standardizedFileURL)
        #expect(try Data(contentsOf: sourceURL) == sourceData)
    }

    @Test("Application undo and redo commands stay available for PDF edits")
    @MainActor
    func appCommandsRoutePDFUndoAndRedo() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-pdf-command-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        let sourceURL = fixtureRoot.appendingPathComponent("Command Fixture.pdf")
        try fixturePDF().write(to: sourceURL, options: .atomic)
        let libraryRoot = fixtureRoot.appendingPathComponent("Library", isDirectory: true)
        let model = AppModel(
            libraryRoot: libraryRoot,
            shortcutReader: ShortcutReader(sandboxed: true)
        )

        await model.start()
        model.accept([sourceURL], source: .drop)
        try await waitUntil {
            model.ingestCount == 0 && model.assets.count == 1
        }
        let asset = try #require(model.assets.first)
        model.openPDFEditor(for: asset.id)
        try await waitUntil { model.pdfEditor?.renderedPage != nil }
        let editor = try #require(model.pdfEditor)
        let original = editor.document

        editor.rotateSelectedPage()
        #expect(AppCommandRouter.availability(of: "edit.undo", in: model) == .available)
        _ = AppCommandRouter.run("edit.undo", in: model)
        #expect(editor.document == original)

        #expect(AppCommandRouter.availability(of: "edit.redo", in: model) == .available)
        _ = AppCommandRouter.run("edit.redo", in: model)
        #expect(editor.selectedPage?.rotation == .degrees90)
        model.closePDFEditor()
    }

    private func fixturePDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(mediaBox)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                20,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0.1,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Editable PDF text", attributes: attributes)
        )
        context.textPosition = CGPoint(x: 24, y: 120)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw PDFEditorTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private actor PDFPersistenceRecorder {
    private var documents: [PDFEditDocument] = []

    var count: Int { documents.count }
    var last: PDFEditDocument? { documents.last }

    func save(_ document: PDFEditDocument) {
        documents.append(document)
    }
}

private enum PDFEditorTestError: Error {
    case timeout
}
