import CoreGraphics
import CoreModel
import Foundation
import PDFEngine
import Testing

@testable import ReelAppCore

/// Opening a block, looking at it, and closing it unchanged is not an edit. It
/// must not write the file, and it must not push an undo step whose only effect
/// is to restore what is already on screen.
@Suite("No-op edits leave the document alone", .serialized)
struct NoOpEditTests {
    @Test("A PDF patch that changes nothing is not committed")
    @MainActor
    func pdfNoOpPatchIsNotCommitted() throws {
        let editor = try makeEditor()
        let before = editor.document
        let page = try #require(editor.document.pages.first)

        try editor.perform(.updatePage(page), actionName: "Update Page")

        #expect(editor.document == before)
        // No undo step means nothing was committed, and nothing committed means
        // the file was never rewritten.
        #expect(!editor.undoManager.canUndo)
    }

    @Test("A PDF patch that changes something is still committed")
    @MainActor
    func pdfRealPatchIsCommitted() throws {
        let editor = try makeEditor()
        let before = editor.document
        var page = try #require(editor.document.pages.first)
        page.rotation = page.rotation.rotatedClockwise()

        try editor.perform(.updatePage(page), actionName: "Rotate Page")

        #expect(editor.document != before)
        #expect(editor.undoManager.canUndo)
    }

    @MainActor
    private func makeEditor() throws -> PDFEditorViewModel {
        let source = try PDFiumDocument(data: fixturePDF())
        let document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf-noop-fixture"),
            title: "No-op Fixture"
        )
        return PDFEditorViewModel(
            document: document,
            sourceURL: URL(fileURLWithPath: "/tmp/clip-noop-fixture.pdf"),
            source: source,
            fontStore: PDFOpenFontStore(
                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clip-pdf-noop-tests-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            automaticallyResolveMissingFonts: false,
            persisting: { _ in }
        )
    }

    private func fixturePDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
