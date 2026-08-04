import CoreGraphics
import CoreModel
import CoreText
import Foundation
import PDFEngine
import Testing

@testable import ReelAppCore

@Suite("PDF editor mutation path")
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
        timeout: Duration = .seconds(2),
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

    func save(_ document: PDFEditDocument) {
        documents.append(document)
    }
}

private enum PDFEditorTestError: Error {
    case timeout
}
