import CoreGraphics
import CoreModel
import CoreText
import Foundation
import Testing

@testable import PDFEngine

@Suite("PDFium document engine")
struct PDFiumDocumentTests {
    @Test("Missing-font resolution stays offline when downloads are disabled")
    func fontResolutionHonorsOfflineMode() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-offline-font-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = PDFOpenFontStore(cacheDirectory: cache)
        let resolution = try await store.resolve(
            PDFFontDescriptor(
                postScriptName: "ABCDEF+DefinitelyMissingFont",
                isEmbedded: true,
                isSubset: true
            ),
            requiredCharacters: Set("New € text"),
            allowsDownload: false
        )
        #expect(resolution == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("PDFium opens, measures, renders, rotates, and extracts text")
    func completeReadPipeline() throws {
        let engine = try PDFiumDocument(data: fixturePDF())
        #expect(engine.pageCount == 2)
        #expect(try engine.pageSize(at: 0) == PDFPageSize(width: 320, height: 180))

        let image = try engine.renderPage(at: 0, maxPixelDimension: 640)
        #expect(image.width == 640)
        #expect(image.height == 360)
        #expect(try hasNonWhitePixels(image))

        let rotated = try engine.renderPage(
            at: 0,
            maxPixelDimension: 640,
            rotation: .degrees90
        )
        #expect(rotated.width == 360)
        #expect(rotated.height == 640)

        let analysis = try engine.analyzePage(at: 0)
        #expect(analysis.text.contains("Hello PDFium"))
        #expect(analysis.glyphs.contains { $0.text == "H" && $0.bounds != nil })
        #expect(analysis.textBlocks.contains { $0.text.contains("Hello PDFium") })
        #expect(
            analysis.fonts.contains {
                $0.postScriptName.localizedCaseInsensitiveContains("Helvetica")
            })

        let document = try engine.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "fixture"),
            title: "Fixture"
        )
        #expect(document.pages.count == 2)
        #expect(document.pages.map(\.sourcePageIndex) == [0, 1])
    }

    @Test("Direct text edits stay selectable in a vector-preserving export")
    func directTextExport() throws {
        let source = try PDFiumDocument(data: fixturePDF())
        let analysis = try source.analyzePage(at: 0)
        let block = try #require(
            analysis.textBlocks.first { $0.text.contains("Hello PDFium") }
        )
        var document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "fixture"),
            title: "Fixture"
        )
        let pageID = document.pages[0].id
        let edit = PDFTextLayer(
            text: "PDFium Hello",
            frame: block.bounds,
            font: block.font,
            fontSize: block.fontSize,
            color: block.color,
            sourceReference: PDFSourceTextReference(
                pageObjectIndex: block.pageObjectIndex,
                originalText: block.text,
                originalFontPostScriptName: block.font.postScriptName
            )
        )
        _ = try document.apply(.addLayer(.text(edit), to: pageID, atIndex: 0))

        let requestedOutput = ProcessInfo.processInfo.environment["CLIP_PDF_DIRECT_QA_OUTPUT"].map {
            URL(fileURLWithPath: $0)
        }
        let output =
            requestedOutput
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "clip-direct-pdf-edit-\(UUID().uuidString).pdf"
            )
        defer {
            if requestedOutput == nil { try? FileManager.default.removeItem(at: output) }
        }
        try PDFDocumentRenderer(source: source).export(document, to: output)

        let exported = try PDFiumDocument(url: output)
        let exportedText = try exported.analyzePage(at: 0).text
        #expect(exportedText.contains("PDFium Hello"))
        #expect(!exportedText.contains("Hello PDFium"))
    }

    @Test("Replacement fonts preserve Unicode text and spaces")
    func replacementFontExport() throws {
        let systemFontURL = URL(fileURLWithPath: "/System/Library/Fonts/SFNS.ttf")
        guard FileManager.default.fileExists(atPath: systemFontURL.path) else { return }
        let fontData = try Data(contentsOf: systemFontURL)
        let source = try PDFiumDocument(data: fixturePDF())
        let block = try #require(
            source.analyzePage(at: 0).textBlocks.first { $0.text.contains("Hello PDFium") }
        )
        var document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "replacement-font-fixture"),
            title: "Replacement Font Fixture"
        )
        let replacementName = "ClipQAFallback"
        let edit = PDFTextLayer(
            text: "Clip PDF Editor",
            frame: block.bounds,
            font: PDFFontDescriptor(
                postScriptName: replacementName,
                familyName: "System Sans",
                isEmbedded: true,
                isSubset: false
            ),
            fontSize: block.fontSize,
            color: block.color,
            sourceReference: PDFSourceTextReference(
                pageObjectIndex: block.pageObjectIndex,
                originalText: block.text,
                originalFontPostScriptName: block.font.postScriptName
            )
        )
        _ = try document.apply(.addLayer(.text(edit), to: document.pages[0].id, atIndex: 0))

        let requestedOutput = ProcessInfo.processInfo.environment[
            "CLIP_PDF_REPLACEMENT_QA_OUTPUT"
        ].map { URL(fileURLWithPath: $0) }
        let output =
            requestedOutput
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "clip-replacement-font-\(UUID().uuidString).pdf"
            )
        defer {
            if requestedOutput == nil { try? FileManager.default.removeItem(at: output) }
        }
        try PDFDocumentRenderer(
            source: source,
            fontData: { $0 == replacementName ? fontData : nil }
        ).export(document, to: output)

        let exportedText = try PDFiumDocument(url: output).analyzePage(at: 0).text
        #expect(exportedText.contains("Clip PDF Editor"))
        #expect(!exportedText.contains("ClipPDFEditor"))
    }

    @Test("Malformed input fails without leaving a PDFium session")
    func invalidInput() {
        #expect(throws: PDFEngineError.self) {
            _ = try PDFiumDocument(data: Data("not a pdf".utf8))
        }
    }

    @Test("Edited pages render and export through one flattened pipeline")
    func editedRenderAndExport() throws {
        let source = try PDFiumDocument(data: fixturePDF())
        var document = try source.makeEditDocument(
            sourceAssetID: AssetID(rawValue: "fixture"),
            title: "Fixture"
        )
        let pageID = document.pages[0].id
        let redaction = PDFLayer.redaction(
            PDFRedactionLayer(
                regions: [CGRect(x: 0.15, y: 0.2, width: 0.35, height: 0.3)]
            )
        )
        let text = PDFLayer.text(
            PDFTextLayer(
                text: "Reviewed",
                frame: CGRect(x: 0.55, y: 0.15, width: 0.35, height: 0.15),
                fontSize: 22,
                color: RGBA(r: 0.8, g: 0.1, b: 0.1, a: 1)
            )
        )
        _ = try document.apply(.addLayer(redaction, to: pageID, atIndex: 0))
        _ = try document.apply(.addLayer(text, to: pageID, atIndex: 1))

        let renderer = PDFDocumentRenderer(source: source)
        let preview = try renderer.render(document, pageID: pageID, maxPixelDimension: 640)
        #expect(try blackPixelCount(preview) > 5_000)

        let requestedOutput = ProcessInfo.processInfo.environment["REEL_PDF_QA_OUTPUT"].map {
            URL(fileURLWithPath: $0)
        }
        let output =
            requestedOutput
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "reel-pdf-export-\(UUID().uuidString).pdf"
            )
        defer {
            if requestedOutput == nil { try? FileManager.default.removeItem(at: output) }
        }
        try renderer.export(document, to: output)
        try renderer.export(document, to: output)
        let exported = try PDFiumDocument(url: output)
        #expect(exported.pageCount == 2)
        #expect(try exported.analyzePage(at: 0).text.isEmpty)
        #expect(try blackPixelCount(exported.renderPage(at: 0)) > 5_000)
    }

    private func fixturePDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.12, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 60))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                24,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0.1,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Hello PDFium", attributes: attributes)
        )
        context.textPosition = CGPoint(x: 24, y: 120)
        CTLineDraw(line, context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(mediaBox.insetBy(dx: 30, dy: 30))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func hasNonWhitePixels(_ image: CGImage) throws -> Bool {
        guard let data = image.dataProvider?.data as Data? else {
            throw PDFEngineError.renderFailed
        }
        return data.enumerated().contains { offset, value in
            offset % 4 != 3 && value < 245
        }
    }

    private func blackPixelCount(_ image: CGImage) throws -> Int {
        guard let data = image.dataProvider?.data as Data? else {
            throw PDFEngineError.renderFailed
        }
        var count = 0
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in stride(from: 0, to: data.count - 3, by: 4) {
                if base[offset] < 12, base[offset + 1] < 12, base[offset + 2] < 12 {
                    count += 1
                }
            }
        }
        return count
    }
}
